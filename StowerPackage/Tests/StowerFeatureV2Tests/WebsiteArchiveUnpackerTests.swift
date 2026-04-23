import Foundation
@testable import StowerFeature
import Testing
import ZIPFoundation

/// Unit tests for `WebsiteArchiveUnpacker`. Zip fixtures are built at runtime
/// via ZIPFoundation to keep the test target free of binary blobs. Each test
/// gets its own scratch directory under the system temp dir so they can run
/// in parallel safely.
@Suite
struct WebsiteArchiveUnpackerTests {
    // MARK: - Happy paths

    @Test
    func unpack_withRootIndexHtml_extractsToRoot() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("site.zip")
        try buildZip(at: zip, entries: [
            "index.html": Data("<html><head><title>Hello</title></head></html>".utf8),
            "style.css": Data("body{}".utf8),
        ])

        let destination = scratch.appendingPathComponent("archive")
        let result = try WebsiteArchiveUnpacker.unpack(zipAt: zip, into: destination)

        #expect(result.indexURL == destination.appendingPathComponent("index.html"))
        #expect(result.title == "Hello")
        #expect(result.entryCount == 2)
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("style.css").path
        ))
    }

    @Test
    func unpack_withSingleTopLevelFolder_leavesStructureIntact() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("nested.zip")
        try buildZip(at: zip, entries: [
            "MyGuide/index.html": Data("<html><title>Guide</title></html>".utf8),
            "MyGuide/assets/app.js": Data("console.log('hi')".utf8),
        ])

        let destination = scratch.appendingPathComponent("archive")
        let result = try WebsiteArchiveUnpacker.unpack(zipAt: zip, into: destination)

        // Entry points at the nested location; files are not moved so the
        // HTML's own relative URLs (and sibling-folder `../` references
        // common in authoring-tool exports) resolve exactly as authored.
        #expect(
            WebsiteArchiveUnpacker.relativePath(of: result.indexURL, in: destination)
                == "MyGuide/index.html"
        )
        #expect(result.title == "Guide")
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("MyGuide/assets/app.js").path
        ))
    }

    @Test
    func unpack_resolvesHeroImage_usingParentRelativeSrc() throws {
        // Layout mirrors the real-world "Archive.zip" case: the index
        // lives under `guide/` and references a hero image via
        // `../guide-assets/...`. Without promoting, that path stays valid
        // both on disk and in the running LocalArchiveServer.
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("parent-relative.zip")
        try buildZip(at: zip, entries: [
            "guide/index.html": Data("""
            <html><head>
              <title>Here Where We Live</title>
              <meta property="og:image" content="../guide-assets/cover.jpg">
            </head></html>
            """.utf8),
            "guide-assets/cover.jpg": Data(repeating: 0x11, count: 16),
        ])

        let destination = scratch.appendingPathComponent("archive")
        let result = try WebsiteArchiveUnpacker.unpack(zipAt: zip, into: destination)

        #expect(result.title == "Here Where We Live")
        #expect(result.heroImageRelativePath == "guide-assets/cover.jpg")
    }

    @Test
    func unpack_missingTitleTag_returnsNilTitle() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("no-title.zip")
        try buildZip(at: zip, entries: [
            "index.html": Data("<html><body>no title</body></html>".utf8),
        ])

        let destination = scratch.appendingPathComponent("archive")
        let result = try WebsiteArchiveUnpacker.unpack(zipAt: zip, into: destination)

        #expect(result.title == nil)
    }

    @Test
    func extractTitle_fallsBackToOgTitle_whenHeadTitleMissing() {
        let html = """
        <html><head>
          <meta property="og:title" content="Here Where We Live Is Our Country">
        </head><body></body></html>
        """
        #expect(
            WebsiteArchiveUnpacker.extractTitle(fromHTML: html)
                == "Here Where We Live Is Our Country"
        )
    }

    @Test
    func extractTitle_fallsBackToH1_whenTitleAndOgMissing() {
        let html = """
        <html><body>
          <h1><span>Here Where We Live Is Our Country</span></h1>
        </body></html>
        """
        #expect(
            WebsiteArchiveUnpacker.extractTitle(fromHTML: html)
                == "Here Where We Live Is Our Country"
        )
    }

    @Test
    func extractTitle_ignoresSvgTitleTag() {
        // A <title> inside <svg> is a tooltip for the icon, not the page.
        let html = """
        <html><head>
          <svg><title>Menu icon</title></svg>
          <title>Real Page Title</title>
        </head></html>
        """
        #expect(
            WebsiteArchiveUnpacker.extractTitle(fromHTML: html) == "Real Page Title"
        )
    }

    @Test
    func extractTitle_collapsesWhitespaceInH1() {
        let html = """
        <html><body>
          <h1>
            Here Where We Live
            Is Our Country
          </h1>
        </body></html>
        """
        #expect(
            WebsiteArchiveUnpacker.extractTitle(fromHTML: html)
                == "Here Where We Live Is Our Country"
        )
    }

    @Test
    func unpack_entitiesInTitle_areUnescaped() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("entities.zip")
        try buildZip(at: zip, entries: [
            "index.html": Data("<html><title>Ben &amp; Jerry&#39;s</title></html>".utf8),
        ])

        let destination = scratch.appendingPathComponent("archive")
        let result = try WebsiteArchiveUnpacker.unpack(zipAt: zip, into: destination)

        #expect(result.title == "Ben & Jerry's")
    }

    // MARK: - Hero image extraction

    @Test
    func unpack_populatesHeroImage_fromOgImage() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("og.zip")
        try buildZip(at: zip, entries: [
            "index.html": Data("""
            <html><head>
              <title>t</title>
              <meta property="og:image" content="images/cover.jpg">
            </head></html>
            """.utf8),
            "images/cover.jpg": Data(repeating: 0xAB, count: 16),
        ])

        let destination = scratch.appendingPathComponent("archive")
        let result = try WebsiteArchiveUnpacker.unpack(zipAt: zip, into: destination)
        #expect(result.heroImageRelativePath == "images/cover.jpg")
    }

    @Test
    func unpack_populatesHeroImage_fromFirstImg_whenMetaMissing() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("img.zip")
        try buildZip(at: zip, entries: [
            "index.html": Data("""
            <html><body>
              <img src="cover.png" alt="cover">
            </body></html>
            """.utf8),
            "cover.png": Data(repeating: 0xCD, count: 16),
        ])

        let destination = scratch.appendingPathComponent("archive")
        let result = try WebsiteArchiveUnpacker.unpack(zipAt: zip, into: destination)
        #expect(result.heroImageRelativePath == "cover.png")
    }

    @Test
    func unpack_skipsAbsoluteHeroImage_asUnusableOffline() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("absolute.zip")
        try buildZip(at: zip, entries: [
            "index.html": Data("""
            <html><head>
              <meta property="og:image" content="https://cdn.example.com/cover.jpg">
            </head></html>
            """.utf8),
        ])

        let destination = scratch.appendingPathComponent("archive")
        let result = try WebsiteArchiveUnpacker.unpack(zipAt: zip, into: destination)
        #expect(result.heroImageRelativePath == nil)
    }

    @Test
    func unpack_rejectsHeroImage_thatEscapesArchiveRoot() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("traversal-hero.zip")
        try buildZip(at: zip, entries: [
            "index.html": Data("""
            <html><head>
              <meta property="og:image" content="../../outside.jpg">
            </head></html>
            """.utf8),
        ])

        let destination = scratch.appendingPathComponent("archive")
        let result = try WebsiteArchiveUnpacker.unpack(zipAt: zip, into: destination)
        #expect(result.heroImageRelativePath == nil)
    }

    // MARK: - Rejection paths

    @Test
    func unpack_missingIndexHtml_throwsNoIndexHTML() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("no-index.zip")
        try buildZip(at: zip, entries: [
            "readme.txt": Data("just a readme".utf8),
        ])

        let destination = scratch.appendingPathComponent("archive")
        #expect(throws: WebsiteArchiveUnpacker.UnpackError.self) {
            _ = try WebsiteArchiveUnpacker.unpack(zipAt: zip, into: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func unpack_pathTraversal_throwsAndLeavesNoResidue() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("evil.zip")
        try buildZip(at: zip, entries: [
            "index.html": Data("<html><title>x</title></html>".utf8),
            "../escaped.txt": Data("pwn".utf8),
        ])

        let destination = scratch.appendingPathComponent("archive")
        #expect(throws: WebsiteArchiveUnpacker.UnpackError.self) {
            _ = try WebsiteArchiveUnpacker.unpack(zipAt: zip, into: destination)
        }
        // Destination is wiped on any UnpackError.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        // The traversal target must not have been written.
        let escaped = scratch.appendingPathComponent("escaped.txt")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }

    @Test
    func unpack_exceedingUncompressedCap_throws() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("too-big.zip")
        // 300 KB of 'A' bytes — will blow a 200 KB cap.
        let big = Data(repeating: UInt8(ascii: "A"), count: 300 * 1024)
        try buildZip(at: zip, entries: [
            "index.html": Data("<html><title>t</title></html>".utf8),
            "big.bin": big,
        ])

        let destination = scratch.appendingPathComponent("archive")
        #expect(throws: WebsiteArchiveUnpacker.UnpackError.self) {
            _ = try WebsiteArchiveUnpacker.unpack(
                zipAt: zip,
                into: destination,
                maxUncompressedBytes: 200 * 1024
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Helpers

    private func makeScratchDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebsiteArchiveUnpackerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a zip at `url` containing the given `path → bytes` entries.
    /// Each entry is compressed with the default compression method.
    private func buildZip(at url: URL, entries: [String: Data]) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size -> Data in
                    let start = Int(position)
                    let end = min(start + size, data.count)
                    return data.subdata(in: start..<end)
                }
            )
        }
    }
}
