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

    /// Viewport the capture WebView lays out at.
    ///
    /// This is load-bearing for image quality, not cosmetic. Responsive images
    /// pick their source from `srcset` + `sizes`, and `sizes` is usually
    /// viewport-relative (`100vw` on Substack, most CMSs, and most news
    /// sites). Capturing at `.zero` made `100vw` resolve to 0, so the browser
    /// selected the *smallest* candidate every time — Substack's 424w variant
    /// out of 424/848/1272/1456 — and `normalizeRenderedResources` then
    /// stripped `srcset`, baking that thumbnail in permanently. Every archived
    /// article ended up with images too small and too soft to fill a phone
    /// column, let alone a 3x one.
    ///
    /// 1024pt wide selects a candidate around 1272w on typical `srcset`
    /// ladders — enough for a 3x phone and a Mac window, without pulling the
    /// largest variant of every image into the offline archive.
    private static let captureViewport = CGRect(x: 0, y: 0, width: 1024, height: 1366)

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        self.webView = WKWebView(frame: Self.captureViewport, configuration: configuration)
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
        try await annotateHiddenContent()

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

    /// Marks elements the page is not actually showing, so extraction can drop
    /// them.
    ///
    /// Extraction runs on the serialized DOM with SwiftSoup, which has no CSS
    /// engine — so anything a page keeps in the DOM but hides with CSS gets
    /// read as article text. Quiz widgets that stack every question and *both*
    /// the "correct" and "incorrect" explanations as `display:none` panels,
    /// inactive tabs, collapsed accordions and off-screen menus all came
    /// through as walls of nonsense.
    ///
    /// The capture WebView does have a CSS engine, so the visibility question
    /// is answered here, where it can actually be answered, and the result is
    /// recorded as an attribute for `RenderedArticleExtractor` to act on.
    ///
    /// Marking (not removing) keeps the Original View archive faithful — the
    /// elements are invisible there anyway.
    ///
    /// Deliberately conservative:
    ///   * Only `display:none` / `visibility:hidden|collapse` count. Zero-size
    ///     and off-viewport elements are left alone, because that is also what
    ///     lazy-loaded and not-yet-scrolled-to content looks like.
    ///   * Anything containing media is left alone. Carousels legitimately
    ///     hide every slide but the active one, so marking on visibility alone
    ///     deleted whole galleries — on a How-To Geek article, 20 of its 26
    ///     images sat inside a `display:none` wrapper.
    ///   * If marking would hide nearly all of the page's text the whole pass
    ///     is abandoned, so a page still mid-hydration is never gutted.
    private func annotateHiddenContent() async throws {
        try await javascriptVoid("""
            (() => {
              const body = document.body;
              if (!body) return true;

              const totalText = (body.textContent || '').trim().length;
              const MEDIA = 'img, picture, video, audio, figure, iframe, svg';
              const candidates = [];
              for (const el of body.querySelectorAll('*')) {
                if (el.closest('[data-stower-hidden]')) continue;
                const style = window.getComputedStyle(el);
                if (style.display !== 'none'
                    && style.visibility !== 'hidden'
                    && style.visibility !== 'collapse') {
                  continue;
                }
                // Hidden media is usually an off-screen carousel slide, which
                // is content worth keeping. Only hidden *text* is dropped.
                if (el.matches(MEDIA) || el.querySelector(MEDIA)) continue;
                if (!(el.textContent || '').trim()) continue;
                candidates.push(el);
              }

              // Bail out if what is left would be too thin to be the article.
              let hiddenText = 0;
              for (const el of candidates) {
                hiddenText += (el.textContent || '').trim().length;
              }
              if (totalText > 0 && (totalText - hiddenText) < Math.max(400, totalText * 0.15)) {
                return true;
              }

              for (const el of candidates) {
                el.setAttribute('data-stower-hidden', '1');
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

/// Failures while loading a page for capture.
///
/// These reach the user directly — the add-URL sheet and the failed-import
/// banner both show `localizedDescription`. Without `LocalizedError` the
/// default description is raw Swift internals ("The operation couldn't be
/// completed. (StowerFeature.(unknown context at $10686a9c4)
/// .CaptureNavigationError error 1.)"), which tells nobody anything.
private enum CaptureNavigationError: Error, LocalizedError {
    case timeout
    case navigationFailed(Error)
    case loadRejected

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "The page took too long to load. It may be very large, very slow, or blocking automated readers."
        case .navigationFailed(let underlying):
            return "The page couldn't be loaded: \(underlying.localizedDescription)"
        case .loadRejected:
            return "The page refused to load. It may require a login or block automated readers."
        }
    }
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
