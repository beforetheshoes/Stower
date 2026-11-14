import Foundation
import Network
@testable import StowerFeature
import Testing
import WebKit

@Suite(.serialized)
struct WebArticleCaptureIntegrationTests {
    @Test
    @MainActor
    func recognizesArticleContentHiddenDuringClientSideHydration() async throws {
        let page = WebPage()
        let html = """
            <!doctype html><html><head></head><body>
            <article style="display: none;">
              <h1>Delivered before hydration finishes</h1>
              <p>This article is already present in the document even though client-side JavaScript has not made it visible yet.</p>
            </article>
            </body></html>
            """
        for try await event in page.load(
            Data(html.utf8),
            mimeType: "text/html",
            characterEncoding: .utf8,
            baseURL: URL(string: "https://example.com/article")!
        ) where event == .finished {
            break
        }

        let visibleText = try await page.callJavaScript(
            "return document.body ? document.body.innerText : '';"
        ) as? String
        let deliveredText = try await page.callJavaScript(
            "return \(WebCaptureDOMProbe.deliveredTextJavaScript);"
        ) as? String

        #expect(!WebCaptureDOMProbe.containsUsableText(visibleText))
        #expect(WebCaptureDOMProbe.containsUsableText(deliveredText))
    }

    @Test
    @MainActor
    func capturesJavaScriptRenderedPageAndReplaysOffline() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-capture-fixture-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let html = """
            <!doctype html><html><head><title>Shell</title></head><body>
            <main id="mount"></main>
            <script>
              setTimeout(() => {
                document.title = 'Rendered fixture title';
                document.getElementById('mount').innerHTML = `
                  <article><h1>Rendered fixture title</h1>
                  <p>The JavaScript-rendered article body survives after the fixture server is stopped.</p>
                  <img src="fixture.png" alt="fixture image">
                  <svg viewBox="0 0 20 20"><circle cx="10" cy="10" r="8"></circle></svg>
                  </article>`;
              }, 50);
            </script></body></html>
            """
        try Data(html.utf8).write(to: fixture.appendingPathComponent("index.html"))
        try Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
            .write(to: fixture.appendingPathComponent("fixture.png"))

        let server = LocalArchiveServer(archiveDir: fixture, articlePath: "/", originURL: nil)
        let port = try await server.start()
        let sourceURL = URL(string: "http://localhost:\(port)/")!
        let captured = try await WebArticleCaptureClient.live.capture(sourceURL)
        #expect(captured.ingestion.title == "Rendered fixture title")
        #expect(captured.ingestion.plainText.contains("JavaScript-rendered article body"))
        #expect(captured.ingestion.sourceHTML.contains("fixture image"))
        server.stop()

        let itemID = UUID()
        defer { AssetArchiver.deleteArchive(for: itemID) }
        defer {
            try? FileManager.default.removeItem(
                at: captured.artifact.stagedPackageURL.deletingLastPathComponent()
            )
        }
        try ArticleCapturePackage.install(captured.artifact, for: itemID)

        let readerURL = try #require(ArticleCapturePackage.archiveURL(for: itemID, original: false))
        let originalURL = try #require(ArticleCapturePackage.archiveURL(for: itemID, original: true))
        let readerText = try await replayText(from: readerURL, baseURL: sourceURL)
        let originalText = try await replayText(from: originalURL, baseURL: sourceURL)
        #expect(readerText.contains("JavaScript-rendered article body"))
        #expect(originalText.contains("JavaScript-rendered article body"))
    }

    @Test(.timeLimit(.minutes(2)))
    @MainActor
    func lazyImagesBelowTheFoldAreInBothArchives() async throws {
        // The capture view never scrolls. Images below the fold are either
        // natively lazy, and start loading only when capture makes them
        // eager, or sit behind a script-driven loader's placeholder.
        let server = try SlowImageServer(imageDelay: .milliseconds(2500))
        let port = try await server.start()
        defer { server.stop() }
        let sourceURL = try #require(URL(string: "http://localhost:\(port)/"))

        let captured = try await WebArticleCaptureClient.live.capture(sourceURL)
        #expect(captured.ingestion.processingState == .ready)

        let itemID = UUID()
        defer { AssetArchiver.deleteArchive(for: itemID) }
        defer {
            try? FileManager.default.removeItem(
                at: captured.artifact.stagedPackageURL.deletingLastPathComponent()
            )
        }
        try ArticleCapturePackage.install(captured.artifact, for: itemID)

        for original in [true, false] {
            let archiveURL = try #require(ArticleCapturePackage.archiveURL(for: itemID, original: original))
            let resources = try archivedResourceURLs(in: archiveURL)
            for image in ["slow.png", "deferred-a.png", "deferred-b.png"] {
                #expect(
                    resources.contains { $0.hasSuffix("/" + image) },
                    "The \(original ? "original" : "reader") archive is missing \(image)"
                )
            }
        }
    }

    private func archivedResourceURLs(in archiveURL: URL) throws -> [String] {
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: archiveURL),
            format: nil
        )
        let archive = try #require(plist as? [String: Any])
        let subresources = archive["WebSubresources"] as? [[String: Any]] ?? []
        return subresources.compactMap { $0["WebResourceURL"] as? String }
    }

    @MainActor
    private func replayText(from archiveURL: URL, baseURL: URL) async throws -> String {
        let page = WebPage()
        let data = try Data(contentsOf: archiveURL)
        for try await event in page.load(
            data,
            mimeType: "application/x-webarchive",
            characterEncoding: .utf8,
            baseURL: baseURL
        ) where event == .finished {
            break
        }
        return try await page.callJavaScript("return document.body ? document.body.innerText : '';") as? String ?? ""
    }
}

/// A tiny HTTP server whose page loads at once and whose image does not.
private final class SlowImageServer: Sendable {
    private let listener: NWListener
    private let imageDelay: Duration
    private let queue = DispatchQueue(label: "SlowImageServer")

    init(imageDelay: Duration) throws {
        self.listener = try NWListener(using: .tcp, on: .any)
        self.imageDelay = imageDelay
    }

    func start() async throws -> UInt16 {
        let imageDelay = self.imageDelay
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = String(bytes: data ?? Data(), encoding: .utf8) ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                if path.hasSuffix("slow.png") {
                    let delay = Double(imageDelay.components.seconds)
                        + Double(imageDelay.components.attoseconds) / 1e18
                    queue.asyncAfter(deadline: .now() + delay) {
                        Self.respond(on: connection, type: "image/png", body: Self.onePixelPNG)
                    }
                } else if path.hasSuffix(".png") {
                    Self.respond(on: connection, type: "image/png", body: Self.onePixelPNG)
                } else {
                    Self.respond(on: connection, type: "text/html; charset=utf-8", body: Data(Self.page.utf8))
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private static func respond(on connection: NWConnection, type: String, body: Data) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let placeholder = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="

    private static let page = """
        <!doctype html><html><head><title>Slow image fixture</title></head><body>
        <article><h1>Slow image fixture</h1>
        <p>This article has one image, and the server takes its time sending it. The text is here
        from the start, so the page looks finished long before the picture arrives.</p>
        <div style="height: 6000px"></div>
        <figure><img loading="lazy" src="slow.png" alt="A late image" width="600" height="400"></figure>
        <figure><img class="lazyload" src="\(placeholder)" data-src="deferred-a.png" alt="Deferred" width="600" height="400"></figure>
        <figure><img class="lazyload" src="\(placeholder)" data-src="deferred-b.png" alt="Deferred too" width="600" height="400"></figure>
        <p>A second paragraph, so there is plainly an article here for the reader to extract.</p>
        </article></body></html>
        """

    private static let onePixelPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    ) ?? Data()
}
