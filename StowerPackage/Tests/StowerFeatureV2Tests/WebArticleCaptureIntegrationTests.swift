import Foundation
@testable import StowerFeature
import Testing
import WebKit

@Suite(.serialized)
struct WebArticleCaptureIntegrationTests {
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
