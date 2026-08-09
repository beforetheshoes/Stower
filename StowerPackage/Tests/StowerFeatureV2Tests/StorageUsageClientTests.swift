import Dependencies
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct StorageUsageClientTests {
    private struct Fixture {
        var roots: StorageRoots
        var client: StorageUsageClient
        var scratch: URL

        func path(_ components: String...) -> URL {
            components.reduce(scratch) { $0.appendingPathComponent($1) }
        }
    }

    private func makeFixture() throws -> Fixture {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-usage-tests-\(UUID().uuidString)", isDirectory: true)
        let roots = StorageRoots(
            archiveRoot: scratch.appendingPathComponent("StowerArchive", isDirectory: true),
            imagesRoot: scratch.appendingPathComponent("StowerImages", isDirectory: true),
            cachesRoot: scratch.appendingPathComponent("StowerImageCache", isDirectory: true),
            pendingRoots: [
                scratch.appendingPathComponent("PendingPDFs", isDirectory: true),
                scratch.appendingPathComponent("PendingWebsites", isDirectory: true),
            ],
            temporaryRoots: [scratch.appendingPathComponent("tmp", isDirectory: true)],
            legacyDatabaseURL: scratch.appendingPathComponent("SQLiteData.db"),
            databaseURL: scratch.appendingPathComponent("stower.sqlite")
        )
        for dir in [roots.archiveRoot, roots.imagesRoot, roots.cachesRoot] + roots.pendingRoots + roots.temporaryRoots {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return Fixture(roots: roots, client: .live(roots: roots), scratch: scratch)
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    private func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test
    func snapshot_accountsPerCategoryAndLargestItems() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let bigItem = UUID()
        let smallItem = UUID()
        try write(4096, to: fixture.roots.archiveRoot.appendingPathComponent("\(bigItem.uuidString)/index.html"))
        try write(1024, to: fixture.roots.archiveRoot.appendingPathComponent("\(smallItem.uuidString)/index.html"))
        try write(512, to: fixture.roots.imagesRoot.appendingPathComponent("hero.jpg"))
        try write(256, to: fixture.roots.pendingRoots[0].appendingPathComponent("stranded.pdf"))
        try write(128, to: fixture.roots.legacyDatabaseURL!)

        let snapshot = try await withDependencies {
            $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
            $0.storageMaintenanceClient = .noop
        } operation: {
            try await fixture.client.computeSnapshot(true)
        }

        #expect(snapshot.archiveBytes >= 5120)
        #expect(snapshot.imagesBytes >= 512)
        #expect(snapshot.pendingBytes >= 256)
        #expect(snapshot.legacyDatabaseBytes >= 128)
        #expect(snapshot.largestItems.first?.id == bigItem)
        #expect(snapshot.largestItems.count == 2)
        #expect(snapshot.totalBytes > 0)
    }

    @Test
    func strandedStagingSweep_respectsAgeAndActiveJobPaths() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = now.addingTimeInterval(-8 * 24 * 3600)

        // Old and unreferenced: swept.
        let stranded = fixture.roots.pendingRoots[0].appendingPathComponent("stranded.pdf")
        try write(100, to: stranded)
        try setModificationDate(old, at: stranded)
        // Old but referenced by a retryable job: kept.
        let active = fixture.roots.pendingRoots[0].appendingPathComponent("active.pdf")
        try write(100, to: active)
        try setModificationDate(old, at: active)
        // Old website dir whose payload points inside it: kept.
        let activeSiteDir = fixture.roots.pendingRoots[1].appendingPathComponent("site-dir", isDirectory: true)
        try write(100, to: activeSiteDir.appendingPathComponent("guide.zip"))
        try setModificationDate(old, at: activeSiteDir)
        // Fresh and unreferenced: kept (may be about to be enqueued).
        let fresh = fixture.roots.pendingRoots[0].appendingPathComponent("fresh.pdf")
        try write(100, to: fresh)

        let report = try await withDependencies {
            $0.date = .constant(now)
            $0.storageMaintenanceClient = StorageMaintenanceClient(
                databaseStats: { DatabaseStorageStats() },
                clearDeadImageAssetBlobs: { 0 },
                sweepOrphanedSyncRows: { 0 },
                activeJobPayloadPaths: {
                    [
                        active.path,
                        activeSiteDir.appendingPathComponent("guide.zip").path,
                    ]
                },
                checkpoint: {},
                vacuum: {}
            )
        } operation: {
            try await fixture.client.runMaintenance(.periodic)
        }

        #expect(!FileManager.default.fileExists(atPath: stranded.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(FileManager.default.fileExists(atPath: activeSiteDir.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(report.freedBytes >= 100)
    }

    @Test
    func captureZipSweep_removesOnlyInstalledZips() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let itemID = UUID()
        let captureDir = fixture.roots.archiveRoot
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
            .appendingPathComponent(ArticleCapturePackage.captureDirectoryName, isDirectory: true)
        let legacyZip = captureDir.appendingPathComponent(ArticleCapturePackage.installedPackageFilename)
        let keeper = captureDir.appendingPathComponent(ArticleCapturePackage.readerArchiveFilename)
        try write(2048, to: legacyZip)
        try write(64, to: keeper)
        // Mid-install staging dirs must not be touched.
        let staging = fixture.roots.archiveRoot
            .appendingPathComponent(".capture-install-\(UUID().uuidString)", isDirectory: true)
        let stagingZip = staging
            .appendingPathComponent(ArticleCapturePackage.captureDirectoryName, isDirectory: true)
            .appendingPathComponent(ArticleCapturePackage.installedPackageFilename)
        try write(2048, to: stagingZip)

        _ = try await withDependencies {
            $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
            $0.storageMaintenanceClient = .noop
        } operation: {
            try await fixture.client.runMaintenance(.periodic)
        }

        #expect(!FileManager.default.fileExists(atPath: legacyZip.path))
        #expect(FileManager.default.fileExists(atPath: keeper.path))
        #expect(FileManager.default.fileExists(atPath: stagingZip.path))
    }

    @Test
    func legacyDatabase_deletedOnUserReclaim_keptByYoungPeriodicPass() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let legacy = fixture.roots.legacyDatabaseURL!
        try write(1024, to: legacy)
        try write(64, to: URL(fileURLWithPath: legacy.path + ".wal"))
        // App Group database created "now" — the 30-day auto-delete gate is
        // not met, so a periodic pass must keep the recovery copy.
        try write(64, to: fixture.roots.databaseURL!)

        let dependencies: (inout DependencyValues) -> Void = {
            $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
            $0.storageMaintenanceClient = .noop
        }

        _ = try await withDependencies(dependencies) {
            try await fixture.client.runMaintenance(.periodic)
        }
        #expect(FileManager.default.fileExists(atPath: legacy.path))

        let report = try await withDependencies(dependencies) {
            try await fixture.client.runMaintenance(.userReclaim)
        }
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path + ".wal"))
        #expect(report.freedBytes >= 1024)
    }
}
