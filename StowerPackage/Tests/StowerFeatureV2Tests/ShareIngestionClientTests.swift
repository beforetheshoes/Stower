import Dependencies
import Foundation
import SQLiteData
@testable import StowerData
import Testing

/// The share extension's half of saving: turn what the user shared into a
/// queued job, copying files somewhere that outlives the extension.
@Suite
struct ShareIngestionClientTests {
    private let now = Date(timeIntervalSince1970: 20_000)

    private func makeRepository() throws -> (any DatabaseWriter, StowerRepository) {
        let database = try StowerDatabase.makeDatabase()
        return (database, StowerRepository.live(database: database, cloudSyncClient: .noop))
    }

    private func jobs(in database: any DatabaseWriter) async throws -> [IngestionJobLocalTable] {
        try await database.read { db in
            try IngestionJobLocalTable.order { $0.createdAt }.fetchAll(db)
        }
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func aSharedURLBecomesAURLJob() async throws {
        let (database, repository) = try makeRepository()
        let url = try #require(URL(string: "https://example.com/post?id=1"))

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await ShareIngestionClient.enqueueURL(url, repository: repository)
        }

        let queued = try await jobs(in: database)
        #expect(queued.map(\.kind) == ["url"])
        #expect(queued.first?.payload == "https://example.com/post?id=1")
        #expect(queued.first?.status == "queued")
    }

    @Test
    func sharedTextKeepsItsTitleHintAndMode() async throws {
        let (database, repository) = try makeRepository()

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await ShareIngestionClient.enqueueText(
                "# Heading\n\nBody",
                titleHint: "From Notes",
                mode: .markdown,
                as: .text,
                repository: repository
            )
        }

        let job = try #require(try await jobs(in: database).first)
        #expect(job.kind == "text")
        let payload = QueuedTextPayloadCodec.decode(job.payload, defaultMode: .auto)
        #expect(payload.content == "# Heading\n\nBody")
        #expect(payload.titleHint == "From Notes")
        #expect(payload.mode == .markdown)
    }

    @Test(arguments: [
        (ShareIngestionClient.StagedKind.pdf, "PendingPDFs", "pdf"),
        (.epub, "PendingEPUBs", "epub"),
        (.website, "PendingWebsites", "website"),
    ])
    func aSharedFileIsCopiedUnderItsOwnNameAndQueued(
        kind: ShareIngestionClient.StagedKind,
        folder: String,
        jobKind: String
    ) async throws {
        let (database, repository) = try makeRepository()
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let container = scratch.appendingPathComponent("container", isDirectory: true)
        let source = scratch.appendingPathComponent("Quarterly Report.bin")
        try Data("contents".utf8).write(to: source)

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await ShareIngestionClient.stageAndEnqueue(
                source,
                as: kind,
                repository: repository,
                container: container
            )
        }

        let job = try #require(try await jobs(in: database).first)
        #expect(job.kind == jobKind)
        let staged = URL(fileURLWithPath: job.payload)
        // The original name survives: it is the title fallback.
        #expect(staged.lastPathComponent == "Quarterly Report.bin")
        #expect(staged.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == folder)
        #expect(try Data(contentsOf: staged) == Data("contents".utf8))
        // Copied, not moved: the extension still owns its original.
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test
    func twoFilesWithTheSameNameDoNotCollide() async throws {
        let (database, repository) = try makeRepository()
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("scan.pdf")
        try Data("pdf".utf8).write(to: source)

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            for _ in 0..<2 {
                try await ShareIngestionClient.stageAndEnqueue(
                    source,
                    as: .pdf,
                    repository: repository,
                    container: scratch
                )
            }
        }

        let paths = try await jobs(in: database).map(\.payload)
        #expect(paths.count == 2)
        #expect(Set(paths).count == 2)
        #expect(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    @Test
    func aMissingFileIsAnErrorAndQueuesNothing() async throws {
        let (database, repository) = try makeRepository()
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.date.now = now
                $0.uuid = .incrementing
            } operation: {
                try await ShareIngestionClient.stageAndEnqueue(
                    scratch.appendingPathComponent("gone.pdf"),
                    as: .pdf,
                    repository: repository,
                    container: scratch
                )
            }
        }
        #expect(try await jobs(in: database).isEmpty)
    }
}
