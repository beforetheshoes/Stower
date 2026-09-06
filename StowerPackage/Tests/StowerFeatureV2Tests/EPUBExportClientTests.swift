import Dependencies
import DependenciesTestSupport
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing
import ZIPFoundation

@Suite(
    .dependencies {
        try $0.bootstrapStowerDatabase(enableSync: false)
        $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
    }
)
struct EPUBExportClientTests {
    @Dependency(\.stowerRepository)
    var repository

    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
    private static let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0])

    @Test
    func exportEmbedsLocalAndDownloadedImages() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let localImage = scratch.appendingPathComponent("local.png")
        try Self.pngBytes.write(to: localImage)

        let item = try await seed(blocks: [
            .paragraph([.text("Hello")]),
            .figure(media: MediaDescriptor(kind: .image, sourceURL: "https://example.com/a.png", localURL: localImage.path)),
            .figure(media: MediaDescriptor(kind: .image, sourceURL: "https://example.com/b.jpg", altText: "Remote")),
        ])
        let requested = LockIsolated<[URL]>([])
        let client = EPUBExportClient.live { url in
            requested.withValue { $0.append(url) }
            return Self.jpegBytes
        }

        let result = try await client.export(item.id)
        defer { Task { await client.discard(result.fileURL) } }

        #expect(result.itemID == item.id)
        #expect(result.suggestedFilename == "Exported")
        #expect(result.fileURL.lastPathComponent == "Exported.epub")
        #expect(requested.value == [URL(string: "https://example.com/b.jpg")!])

        let paths = try archivePaths(at: result.fileURL)
        #expect(paths.first == "mimetype")
        #expect(paths.contains("OEBPS/images/img-1.png"))
        #expect(paths.contains("OEBPS/images/img-2.jpg"))
    }

    @Test
    func failedDownloadStillProducesAnEPUB() async throws {
        let item = try await seed(blocks: [
            .paragraph([.text("Hello")]),
            .figure(media: MediaDescriptor(kind: .image, sourceURL: "https://example.com/b.jpg", altText: "Remote")),
        ])
        let client = EPUBExportClient.live { _ in throw URLError(.timedOut) }

        let result = try await client.export(item.id)
        defer { Task { await client.discard(result.fileURL) } }

        let paths = try archivePaths(at: result.fileURL)
        #expect(!paths.contains { $0.hasPrefix("OEBPS/images/") })
        let chapter = try archiveEntry("OEBPS/chapter.xhtml", at: result.fileURL)
        #expect(chapter.contains("[Image: Remote]"))
    }

    @Test
    func websiteArchivesAreNotExportable() async throws {
        let ingestion = IngestionResult.importedWebsite(title: "Site", filename: "site.zip")
        let item = try await repository.createItemFromIngestion(ingestion)
        let client = EPUBExportClient.live { _ in Data() }

        await #expect(throws: EPUBExportError.notExportable) {
            try await client.export(item.id)
        }
    }

    @Test
    func unknownItemThrows() async throws {
        let client = EPUBExportClient.live { _ in Data() }
        await #expect(throws: EPUBExportError.itemNotFound) {
            try await client.export(UUID())
        }
    }

    @Test
    func discardRemovesTheExportDirectory() async throws {
        let item = try await seed(blocks: [.paragraph([.text("Hello")])])
        let client = EPUBExportClient.live { _ in Data() }
        let result = try await client.export(item.id)
        let directory = result.fileURL.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))

        await client.discard(result.fileURL)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        // Idempotent.
        await client.discard(result.fileURL)
    }

    // MARK: - Helpers

    private func seed(blocks: [ReaderBlock]) async throws -> SavedItem {
        let ingestion = IngestionResult.structuredText(
            title: "Exported",
            blocks: blocks,
            plainText: "Hello"
        )
        return try await repository.createItemFromIngestion(ingestion)
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func archivePaths(at url: URL) throws -> [String] {
        let archive = try Archive(url: url, accessMode: .read)
        return archive.map(\.path)
    }

    private func archiveEntry(_ path: String, at url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try #require(archive[path])
        var bytes = Data()
        _ = try archive.extract(entry) { bytes.append($0) }
        return try #require(String(bytes: bytes, encoding: .utf8))
    }
}
