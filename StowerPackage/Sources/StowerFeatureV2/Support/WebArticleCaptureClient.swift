import Dependencies
import Foundation
import StowerData
import WebKit

public struct CapturedWebArticle: Equatable, Sendable {
    public var ingestion: IngestionResult
    public var artifact: WebCaptureArtifact

    public init(ingestion: IngestionResult, artifact: WebCaptureArtifact) {
        self.ingestion = ingestion
        self.artifact = artifact
    }
}

public struct WebArticleCaptureClient: Sendable {
    public var capture: @Sendable (URL) async throws -> CapturedWebArticle

    public init(capture: @escaping @Sendable (URL) async throws -> CapturedWebArticle) {
        self.capture = capture
    }

    public static let failing = WebArticleCaptureClient { _ in throw URLError(.cannotLoadFromNetwork) }
    public static let live = WebArticleCaptureClient { url in
        try await WebArticleCaptureSession.capture(url)
    }
}

private enum WebArticleCaptureClientKey: DependencyKey {
    static let liveValue = WebArticleCaptureClient.live
    static let testValue = WebArticleCaptureClient.failing
}

extension DependencyValues {
    public var webArticleCaptureClient: WebArticleCaptureClient {
        get { self[WebArticleCaptureClientKey.self] }
        set { self[WebArticleCaptureClientKey.self] = newValue }
    }
}

enum WebCaptureDOMProbe {
    static let deliveredTextJavaScript = "document.body ? document.body.textContent : ''"

    static func containsUsableText(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40
    }
}

@MainActor
private final class WebArticleCaptureSession {
    private let webView: WKWebView
    private let navigator = CaptureNavigationDelegate()

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView.customUserAgent = "Mozilla/5.0 (Macintosh; Apple Silicon Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Stower/1"
        self.webView.navigationDelegate = navigator
    }

    static func capture(_ url: URL) async throws -> CapturedWebArticle {
        let session = WebArticleCaptureSession()
        return try await session.run(url)
    }

    private func run(_ sourceURL: URL) async throws -> CapturedWebArticle {
        var warnings = [String]()
        var completeness = WebCaptureCompleteness.complete
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            try await navigator.load(timeout: .seconds(30)) { self.webView.load(request) }
        } catch CaptureNavigationError.timeout {
            let text = try? await javascriptString(WebCaptureDOMProbe.deliveredTextJavaScript)
            guard WebCaptureDOMProbe.containsUsableText(text) else { throw CaptureNavigationError.timeout }
            completeness = .partial
            warnings.append("The page did not finish loading within 30 seconds; content that had rendered was saved.")
        }

        let settled = await waitForDOMQuiet()
        if !settled {
            completeness = .partial
            warnings.append("The page kept changing while it was saved; late-loading media may be missing.")
        }
        try await normalizeRenderedResources()

        let finalURL = webView.url ?? sourceURL
        let readability = try await runMozillaReadability()
        let originalArchive = try await createWebArchiveData()
        guard let renderedHTML = try await javascriptString("document.documentElement.outerHTML") else {
            throw URLIngestionError.noExtractableContent
        }
        var extraction = try RenderedArticleExtractor.extract(
            renderedHTML: renderedHTML,
            sourceURL: finalURL,
            readability: readability
        )
        extraction.warnings.append(contentsOf: warnings)

        // ReaderDocument remains a derived index for listening/search/AI. The
        // actual reader renders the archive built from the preserved DOM.
        var indexed = try await ExtractionPipelineClient.live.extract(extraction.readerHTML, finalURL)
        indexed.title = extraction.title
        indexed.sourceURL = sourceURL.absoluteString
        indexed.canonicalURL = extraction.canonicalURL ?? finalURL.absoluteString
        indexed.author = extraction.author
        indexed.publishedAt = extraction.publishedAt
        indexed.siteName = extraction.siteName
        indexed.heroImageURL = extraction.heroImageURL
        indexed.plainText = extraction.plainText
        indexed.excerpt = String(extraction.plainText.prefix(220))
        indexed.readingTimeMinutes = estimateReadingTime(text: extraction.plainText)
        indexed.hasRichMedia = indexed.hasRichMedia || extraction.isInteractive
        indexed.renderFormat = extraction.isInteractive ? .webView : .structuredV1
        indexed.processingState = completeness == .complete ? .ready : .partial
        indexed.processingError = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        indexed.sourceHTML = renderedHTML

        try await navigator.load(timeout: .seconds(15)) {
            self.webView.loadHTMLString(extraction.readerHTML, baseURL: finalURL)
        }
        _ = await waitForDOMQuiet(maximum: .seconds(3))
        let readerArchive = try await createWebArchiveData()
        let captureID = UUID()
        let artifact = try ArticleCapturePackage.stage(
            captureID: captureID,
            sourceURL: finalURL,
            content: ArticleCapturePackage.Content(
                readerArchive: readerArchive,
                originalArchive: originalArchive,
                document: indexed.document,
                plainText: indexed.plainText
            ),
            completeness: completeness,
            warnings: warnings
        )
        indexed.webCapture = artifact
        return CapturedWebArticle(ingestion: indexed, artifact: artifact)
    }

    private func normalizeRenderedResources() async throws {
        try await javascriptVoid("""
            (() => {
              for (const image of document.images) {
                const chosen = image.currentSrc || image.src || image.dataset.src || image.dataset.lazySrc;
                if (chosen) image.src = new URL(chosen, document.baseURI).href;
                image.removeAttribute('srcset'); image.removeAttribute('sizes'); image.loading = 'eager';
              }
              for (const source of document.querySelectorAll('picture source,video source,audio source')) {
                const chosen = source.src || source.dataset.src;
                if (chosen) source.src = new URL(chosen, document.baseURI).href;
                source.removeAttribute('srcset');
              }
              for (const media of document.querySelectorAll('[poster]')) {
                media.poster = new URL(media.poster, document.baseURI).href;
              }
              return true;
            })()
            """)
    }

    private func runMozillaReadability() async throws -> MozillaReadabilityResult? {
        guard let scriptURL = Bundle.module.url(forResource: "Readability", withExtension: "js"),
              let source = try? String(contentsOf: scriptURL, encoding: .utf8)
        else { return nil }
        try await javascriptVoid(source)
        let json = try await javascriptString("""
            (() => {
              try {
                const result = new Readability(document.cloneNode(true), { keepClasses: true }).parse();
                return result ? JSON.stringify(result) : null;
              } catch (_) { return null; }
            })()
            """)
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MozillaReadabilityResult.self, from: data)
    }

    private func waitForDOMQuiet(maximum: Duration = .seconds(4)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximum)
        var previous = ""
        var stableSamples = 0
        while clock.now < deadline {
            let signature = (try? await javascriptString("""
                (() => `${document.documentElement.outerHTML.length}:${document.images.length}:${document.querySelectorAll('*').length}`)()
                """)) ?? ""
            if signature == previous, !signature.isEmpty {
                stableSamples += 1
                if stableSamples >= 3 {
                    return true
                }
            } else {
                previous = signature
                stableSamples = 0
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
        return false
    }

    private func javascriptString(_ source: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(source) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as? String)
                }
            }
        }
    }

    private func javascriptVoid(_ source: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(source) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func createWebArchiveData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createWebArchiveData { result in continuation.resume(with: result) }
        }
    }
}

private enum CaptureNavigationError: Error {
    case timeout
    case navigationFailed(Error)
    case loadRejected
}

@MainActor
private final class CaptureNavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    func load(timeout: Duration, action: () -> WKNavigation?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            guard action() != nil else {
                finish(.failure(CaptureNavigationError.loadRejected))
                return
            }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(.failure(CaptureNavigationError.timeout))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        finish(.failure(CaptureNavigationError.navigationFailed(error)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        finish(.failure(CaptureNavigationError.navigationFailed(error)))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased(),
              ["http", "https", "about", "data", "blob"].contains(scheme)
        else {
            return .cancel
        }
        return .allow
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}
