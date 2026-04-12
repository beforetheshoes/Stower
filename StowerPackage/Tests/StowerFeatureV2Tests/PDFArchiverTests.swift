import CoreGraphics
import Foundation
import ImageIO
@testable import StowerFeature
import Testing
import UniformTypeIdentifiers

/// Tests for PDF page-image archiving, on-disk verification, and symlink
/// creation. Serialized because tests write to the shared `StowerArchive`
/// directory on the real filesystem.
@Suite(.serialized)
struct PDFArchiverTests {

    // MARK: - Phase 1: archivePageImage writes a durable, readable JPEG

    @Test
    func archivePageImage_writesReadableJPEG() throws {
        let id = UUID()
        defer { AssetArchiver.deleteArchive(for: id) }

        let image = makeTestImage()
        try PDFArchiver.archivePageImage(image, for: id, pageIndex: 0)

        let url = PDFArchiver.pageImageURL(for: id, pageIndex: 0)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        #expect(data.count > 0)
        // JPEG SOI marker
        #expect(data[0] == 0xFF)
        #expect(data[1] == 0xD8)
    }

    @Test
    func archivePageImage_fileIsDurablyDecodable() throws {
        let id = UUID()
        defer { AssetArchiver.deleteArchive(for: id) }

        let image = makeTestImage(width: 10, height: 10)
        try PDFArchiver.archivePageImage(image, for: id, pageIndex: 0)

        let url = PDFArchiver.pageImageURL(for: id, pageIndex: 0)
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("Written file does not decode as a valid image")
            return
        }
        #expect(decoded.width == 10)
        #expect(decoded.height == 10)
    }

    // MARK: - Phase 2: on-disk verification

    @Test
    func verifyPageImageOnDisk_returnsFalseForMissingFile() {
        let id = UUID()
        #expect(PDFArchiver.verifyPageImageOnDisk(for: id, pageIndex: 0) == false)
    }

    @Test
    func verifyPageImageOnDisk_returnsTrueAfterWrite() throws {
        let id = UUID()
        defer { AssetArchiver.deleteArchive(for: id) }

        let image = makeTestImage()
        try PDFArchiver.archivePageImage(image, for: id, pageIndex: 0)

        #expect(PDFArchiver.verifyPageImageOnDisk(for: id, pageIndex: 0) == true)
    }

    @Test
    func archivePageImage_producesNonEmptyFile() throws {
        let id = UUID()
        defer { AssetArchiver.deleteArchive(for: id) }

        let image = makeTestImage()
        try PDFArchiver.archivePageImage(image, for: id, pageIndex: 0)

        let url = PDFArchiver.pageImageURL(for: id, pageIndex: 0)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? UInt64
        #expect((size ?? 0) > 0)
    }

    // MARK: - Phase 3: symlink creation with target verification

    @Test
    func symlinkPageImages_skipsNonexistentSources() throws {
        let id = UUID()
        let targetDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetDir) }

        let count = PDFArchiver.symlinkPageImages(for: id, into: targetDir)

        #expect(count == 0)
        let contents = try FileManager.default.contentsOfDirectory(
            at: targetDir, includingPropertiesForKeys: nil
        )
        #expect(contents.isEmpty)
    }

    @Test
    func symlinkPageImages_linksExistingImages() throws {
        let id = UUID()
        defer { AssetArchiver.deleteArchive(for: id) }

        let targetDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetDir) }

        let image = makeTestImage()
        for i in 0..<3 {
            try PDFArchiver.archivePageImage(image, for: id, pageIndex: i)
        }

        let count = PDFArchiver.symlinkPageImages(for: id, into: targetDir)

        #expect(count == 3)
        let contents = try FileManager.default.contentsOfDirectory(
            at: targetDir, includingPropertiesForKeys: nil
        )
        #expect(contents.count == 3)

        for url in contents {
            let data = try Data(contentsOf: url)
            #expect(data.count > 0)
        }
    }

    @Test
    func symlinkPageImages_skipsPartialSet() throws {
        let id = UUID()
        defer { AssetArchiver.deleteArchive(for: id) }

        let targetDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetDir) }

        let image = makeTestImage()
        try PDFArchiver.archivePageImage(image, for: id, pageIndex: 0)
        try PDFArchiver.archivePageImage(image, for: id, pageIndex: 2)

        let count = PDFArchiver.symlinkPageImages(for: id, into: targetDir)

        #expect(count == 2)
        let names = try FileManager.default.contentsOfDirectory(
            at: targetDir, includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        #expect(names == ["pdf-page-0.jpg", "pdf-page-2.jpg"])
    }

    // MARK: - Phase 5: relocate page images (canonical URL mismatch fix)

    @Test
    func relocatePageImages_movesAllPagesToNewItemID() throws {
        let sourceID = UUID()
        let destID = UUID()
        defer {
            AssetArchiver.deleteArchive(for: sourceID)
            AssetArchiver.deleteArchive(for: destID)
        }

        let image = makeTestImage()
        for i in 0..<3 {
            try PDFArchiver.archivePageImage(image, for: sourceID, pageIndex: i)
        }

        try PDFArchiver.relocatePageImages(from: sourceID, to: destID)

        // Source should be empty of page images
        #expect(PDFArchiver.pageImageURLs(for: sourceID).isEmpty)

        // Destination should have all 3
        let destURLs = PDFArchiver.pageImageURLs(for: destID)
        #expect(destURLs.count == 3)
        for url in destURLs {
            let data = try Data(contentsOf: url)
            #expect(data.count > 0)
        }
    }

    @Test
    func relocatePageImages_noopWhenSameID() throws {
        let id = UUID()
        defer { AssetArchiver.deleteArchive(for: id) }

        let image = makeTestImage()
        try PDFArchiver.archivePageImage(image, for: id, pageIndex: 0)

        try PDFArchiver.relocatePageImages(from: id, to: id)

        #expect(PDFArchiver.pageImageURLs(for: id).count == 1)
    }

    @Test
    func relocatePageImages_noopWhenSourceEmpty() throws {
        let sourceID = UUID()
        let destID = UUID()

        // Should not throw even when source has no images
        try PDFArchiver.relocatePageImages(from: sourceID, to: destID)

        #expect(PDFArchiver.pageImageURLs(for: destID).isEmpty)
    }

    // MARK: - Phase 4: server integration (PDF page images via symlinks)

    @Test
    func localArchiveServer_returns404_forMissingPDFPageImage() async throws {
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        try Data("<html></html>".utf8).write(
            to: scratchDir.appendingPathComponent("index.html"),
            options: .atomic
        )

        let server = LocalArchiveServer(archiveDir: scratchDir, articlePath: "/", originURL: nil)
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://localhost:\(port)/pdf-page-0.jpg")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 404)
    }

    @Test
    func localArchiveServer_serves200_whenPageImageExists() async throws {
        let id = UUID()
        defer { AssetArchiver.deleteArchive(for: id) }

        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        try Data("<html></html>".utf8).write(
            to: scratchDir.appendingPathComponent("index.html"),
            options: .atomic
        )

        let image = makeTestImage(width: 10, height: 10)
        try PDFArchiver.archivePageImage(image, for: id, pageIndex: 0)
        PDFArchiver.symlinkPageImages(for: id, into: scratchDir)

        let server = LocalArchiveServer(archiveDir: scratchDir, articlePath: "/", originURL: nil)
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://localhost:\(port)/pdf-page-0.jpg")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(data.count > 0)
        #expect(data[0] == 0xFF)
        #expect(data[1] == 0xD8)
    }

    // MARK: - Helpers

    private func makeTestImage(width: Int = 1, height: Int = 1) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
