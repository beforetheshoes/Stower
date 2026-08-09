import Dependencies
import Foundation
import OSLog
import StowerData

private let kStorageLogger = Logger(subsystem: "com.ryanleewilliams.stower", category: "StorageUsage")

// MARK: - Value types

public struct ItemStorageSize: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var bytes: Int

    public init(id: UUID, title: String, bytes: Int) {
        self.id = id
        self.title = title
        self.bytes = bytes
    }
}

/// A point-in-time accounting of everything Stower keeps on disk.
public struct StorageSnapshot: Equatable, Sendable {
    public var databaseFileBytes: Int = 0
    public var databaseWALBytes: Int = 0
    /// Free pages inside the database file that only a VACUUM returns.
    public var databaseReclaimableBytes: Int = 0
    /// `Documents/StowerArchive` — installed article/website/PDF archives.
    public var archiveBytes: Int = 0
    /// `Documents/StowerImages` — persistent downloaded images.
    public var imagesBytes: Int = 0
    /// Self-evicting URLCache under `Library/Caches`.
    public var cachesBytes: Int = 0
    /// Staged share-extension imports in the App Group container.
    public var pendingBytes: Int = 0
    /// Pre-App-Group database copy left in Application Support.
    public var legacyDatabaseBytes: Int = 0
    /// Largest per-item archive directories, descending.
    public var largestItems = [ItemStorageSize]()
    public var computedAt: Date = .distantPast

    public var totalBytes: Int {
        databaseFileBytes + databaseWALBytes + archiveBytes + imagesBytes
            + cachesBytes + pendingBytes + legacyDatabaseBytes
    }

    public init() {}
}

public struct MaintenanceReport: Equatable, Sendable {
    public var freedBytes: Int = 0
    public var steps = [String]()

    public init(freedBytes: Int = 0, steps: [String] = []) {
        self.freedBytes = freedBytes
        self.steps = steps
    }
}

public enum MaintenanceTrigger: Equatable, Sendable {
    /// Launch-time housekeeping: conservative, only vacuums when it pays off.
    case periodic
    /// User tapped "Reclaim Space": sweeps everything and always vacuums.
    case userReclaim
}

// MARK: - Roots

/// Every filesystem location the client touches, injectable for tests.
public struct StorageRoots: Sendable {
    public let archiveRoot: URL
    public let imagesRoot: URL
    public let cachesRoot: URL
    public let pendingRoots: [URL]
    public let temporaryRoots: [URL]
    public let legacyDatabaseURL: URL?
    public let databaseURL: URL?

    public static func live() -> Self {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let temporary = fileManager.temporaryDirectory
        let appGroup = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: StowerDatabase.appGroupID)
        let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return Self(
            archiveRoot: documents.appendingPathComponent("StowerArchive", isDirectory: true),
            imagesRoot: documents.appendingPathComponent("StowerImages", isDirectory: true),
            cachesRoot: caches.appendingPathComponent("StowerImageCache", isDirectory: true),
            pendingRoots: [
                appGroup?.appendingPathComponent("PendingPDFs", isDirectory: true),
                appGroup?.appendingPathComponent("PendingWebsites", isDirectory: true),
            ].compactMap(\.self),
            temporaryRoots: [temporary],
            legacyDatabaseURL: applicationSupport?.appendingPathComponent("SQLiteData.db"),
            databaseURL: appGroup?
                .appendingPathComponent("Database", isDirectory: true)
                .appendingPathComponent("stower.sqlite")
        )
    }

    public init(
        archiveRoot: URL,
        imagesRoot: URL,
        cachesRoot: URL,
        pendingRoots: [URL],
        temporaryRoots: [URL],
        legacyDatabaseURL: URL?,
        databaseURL: URL?
    ) {
        self.archiveRoot = archiveRoot
        self.imagesRoot = imagesRoot
        self.cachesRoot = cachesRoot
        self.pendingRoots = pendingRoots
        self.temporaryRoots = temporaryRoots
        self.legacyDatabaseURL = legacyDatabaseURL
        self.databaseURL = databaseURL
    }
}

// MARK: - Client

/// Filesystem-side storage accounting and reclamation. Database-side work is
/// delegated to `StorageMaintenanceClient`; this client owns directory scans,
/// stranded-file sweeps, and the maintenance orchestration the app and the
/// Settings storage section call into.
public struct StorageUsageClient: Sendable {
    /// Cached (60 s) storage accounting. Pass `force` to rescan.
    public var computeSnapshot: @Sendable (_ force: Bool) async throws -> StorageSnapshot
    /// Runs the full maintenance pass for the given trigger.
    public var runMaintenance: @Sendable (MaintenanceTrigger) async throws -> MaintenanceReport

    public init(
        computeSnapshot: @escaping @Sendable (_ force: Bool) async throws -> StorageSnapshot,
        runMaintenance: @escaping @Sendable (MaintenanceTrigger) async throws -> MaintenanceReport
    ) {
        self.computeSnapshot = computeSnapshot
        self.runMaintenance = runMaintenance
    }

    public static let noop = Self(
        computeSnapshot: { _ in StorageSnapshot() },
        runMaintenance: { _ in MaintenanceReport() }
    )

    public static func live(roots: StorageRoots) -> Self {
        let scanner = StorageScanActor(roots: roots)
        return Self(
            computeSnapshot: { force in
                try await scanner.snapshot(force: force)
            },
            runMaintenance: { trigger in
                try await scanner.runMaintenance(trigger: trigger)
            }
        )
    }
}

// MARK: - Scan actor

/// Serializes scans and maintenance so a "Reclaim Space" tap can't race the
/// launch-time pass, and caches the last snapshot (directory walks over a
/// multi-GB archive are thousands of stat calls).
actor StorageScanActor {
    private let roots: StorageRoots
    private var cached: StorageSnapshot?
    private let cacheLifetime: TimeInterval = 60

    /// Staged Pending* imports younger than this are never swept, even when
    /// no job row references them (a job may be about to be enqueued).
    static let strandedStagingMaxAge: TimeInterval = 7 * 24 * 3600
    /// tmp/ scratch directories younger than this are left alone.
    static let temporaryScratchMaxAge: TimeInterval = 24 * 3600
    /// The legacy sandbox database is auto-deleted once the App Group copy
    /// has been in service this long.
    static let legacyDatabaseRetention: TimeInterval = 30 * 24 * 3600
    /// Periodic vacuums only run when they would reclaim at least this much…
    static let periodicVacuumMinimumBytes = 50 * 1024 * 1024
    /// …and at least this fraction of the database file.
    static let periodicVacuumMinimumFraction = 0.2

    init(roots: StorageRoots) {
        self.roots = roots
    }

    // MARK: Snapshot

    func snapshot(force: Bool) async throws -> StorageSnapshot {
        @Dependency(\.date.now)
        var now
        if !force, let cached, now.timeIntervalSince(cached.computedAt) < cacheLifetime {
            return cached
        }
        var snapshot = StorageSnapshot()
        snapshot.computedAt = now

        @Dependency(\.storageMaintenanceClient)
        var maintenance
        if let stats = try? await maintenance.databaseStats() {
            snapshot.databaseFileBytes = stats.fileBytes
            snapshot.databaseWALBytes = stats.walBytes
            snapshot.databaseReclaimableBytes = stats.reclaimableBytes
        }

        snapshot.imagesBytes = Self.directorySize(roots.imagesRoot)
        snapshot.cachesBytes = Self.directorySize(roots.cachesRoot)
        snapshot.pendingBytes = roots.pendingRoots.reduce(0) { $0 + Self.directorySize($1) }
        snapshot.legacyDatabaseBytes = Self.legacyDatabaseSize(roots.legacyDatabaseURL)

        let (archiveTotal, perItem) = Self.archiveSizes(root: roots.archiveRoot)
        snapshot.archiveBytes = archiveTotal
        snapshot.largestItems = try await Self.titledLargestItems(perItem: perItem)

        cached = snapshot
        return snapshot
    }

    // MARK: Maintenance

    func runMaintenance(trigger: MaintenanceTrigger) async throws -> MaintenanceReport {
        @Dependency(\.date.now)
        var now
        @Dependency(\.storageMaintenanceClient)
        var maintenance
        var report = MaintenanceReport()

        let activePaths = (try? await maintenance.activeJobPayloadPaths()) ?? []
        report.freedBytes += sweepStrandedStaging(now: now, activePaths: activePaths)
        report.steps.append("Swept stranded imports")

        report.freedBytes += sweepTemporaryScratch(now: now)
        report.steps.append("Swept temporary files")

        report.freedBytes += sweepInstalledCaptureZips()
        report.steps.append("Removed redundant capture archives")

        if let removed = try? await maintenance.clearDeadImageAssetBlobs(), removed > 0 {
            report.steps.append("Cleared \(removed) legacy image rows")
        }

        // Orphaned sync rows propagate their deletion to CloudKit, so the
        // caller gates this entire maintenance pass on sync health.
        if let swept = try? await maintenance.sweepOrphanedSyncRows(), swept > 0 {
            report.steps.append("Removed \(swept) orphaned sync rows")
        }

        report.freedBytes += sweepLegacyDatabase(now: now, force: trigger == .userReclaim)

        let statsBefore = try? await maintenance.databaseStats()
        let shouldVacuum: Bool
        switch trigger {
        case .userReclaim:
            shouldVacuum = true
        case .periodic:
            if let stats = statsBefore {
                shouldVacuum = stats.reclaimableBytes >= Self.periodicVacuumMinimumBytes
                    && Double(stats.reclaimableBytes)
                        >= Double(stats.fileBytes) * Self.periodicVacuumMinimumFraction
            } else {
                shouldVacuum = false
            }
        }
        if shouldVacuum {
            do {
                try await maintenance.checkpoint()
                try await maintenance.vacuum()
                if let before = statsBefore, let after = try? await maintenance.databaseStats() {
                    report.freedBytes += max(0, (before.fileBytes + before.walBytes) - (after.fileBytes + after.walBytes))
                }
                report.steps.append("Compacted database")
            } catch let error where error.isDatabaseSuspension {
                // The app was suspended mid-maintenance; the vacuum retries on
                // a future pass. Never fail the whole report over it.
                kStorageLogger.info("VACUUM skipped: database suspended")
            } catch let StorageMaintenanceError.insufficientDiskSpace(required, available) {
                kStorageLogger.warning("VACUUM skipped: needs \(required) bytes, only \(available) free")
            }
        }

        cached = nil
        return report
    }

    // MARK: Sweeps

    /// Removes staged share-extension imports that are old enough to be
    /// abandoned AND not referenced by any job that could still be retried.
    private func sweepStrandedStaging(now: Date, activePaths: Set<String>) -> Int {
        // Directory enumeration resolves symlinks (`/var` → `/private/var`),
        // so payload paths must be normalized the same way before comparison.
        let normalizedActivePaths = Set(activePaths.map(Self.normalizedPath))
        var freed = 0
        for root in roots.pendingRoots {
            for entry in Self.contents(of: root) {
                guard let age = Self.age(of: entry, now: now), age > Self.strandedStagingMaxAge else {
                    continue
                }
                let entryPath = Self.normalizedPath(entry.path)
                let isActive = normalizedActivePaths.contains { payload in
                    payload == entryPath || payload.hasPrefix(entryPath + "/")
                }
                if isActive { continue }
                freed += Self.remove(entry)
            }
        }
        return freed
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func sweepTemporaryScratch(now: Date) -> Int {
        var freed = 0
        for root in roots.temporaryRoots {
            for entry in Self.contents(of: root) {
                let name = entry.lastPathComponent
                guard name == "StowerReader" || name.hasPrefix("StowerCapture-") else { continue }
                guard let age = Self.age(of: entry, now: now), age > Self.temporaryScratchMaxAge else {
                    continue
                }
                freed += Self.remove(entry)
            }
        }
        return freed
    }

    /// Deletes the `capture.zip` older installs left inside each installed
    /// capture directory (its bytes live in the synced chunk rows).
    private func sweepInstalledCaptureZips() -> Int {
        var freed = 0
        for itemDir in Self.contents(of: roots.archiveRoot) {
            // In-flight installs and rollback backups use dot-prefixed
            // directories; leave anything mid-operation alone.
            guard !itemDir.lastPathComponent.hasPrefix(".") else { continue }
            let zip = itemDir
                .appendingPathComponent(ArticleCapturePackage.captureDirectoryName, isDirectory: true)
                .appendingPathComponent(ArticleCapturePackage.installedPackageFilename)
            if FileManager.default.fileExists(atPath: zip.path) {
                freed += Self.remove(zip)
            }
        }
        return freed
    }

    private func sweepLegacyDatabase(now: Date, force: Bool) -> Int {
        guard let legacyURL = roots.legacyDatabaseURL,
              FileManager.default.fileExists(atPath: legacyURL.path)
        else { return 0 }

        if !force {
            // Auto-delete only once the App Group database has been the live
            // copy long enough that the "recovery copy" has no value left.
            guard let databaseURL = roots.databaseURL,
                  let created = try? FileManager.default
                      .attributesOfItem(atPath: databaseURL.path)[.creationDate] as? Date,
                  now.timeIntervalSince(created) >= Self.legacyDatabaseRetention
            else { return 0 }
        }

        var freed = Self.remove(legacyURL)
        freed += Self.remove(URL(fileURLWithPath: legacyURL.path + ".wal"))
        freed += Self.remove(URL(fileURLWithPath: legacyURL.path + ".shm"))
        if freed > 0 {
            kStorageLogger.info("Deleted legacy sandbox database (\(freed) bytes)")
        }
        return freed
    }

    // MARK: Filesystem helpers

    private static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        )) ?? []
    }

    private static func age(of url: URL, now: Date) -> TimeInterval? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        guard let stamp = values?.contentModificationDate ?? values?.creationDate else { return nil }
        return now.timeIntervalSince(stamp)
    }

    /// Removes a file or directory, returning the bytes it occupied.
    private static func remove(_ url: URL) -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let size = itemSize(url)
        do {
            try FileManager.default.removeItem(at: url)
            return size
        } catch {
            kStorageLogger.warning("Failed to remove \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    private static func itemSize(_ url: URL) -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        return isDirectory.boolValue ? directorySize(url) : fileSize(url)
    }

    private static func fileSize(_ url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
    }

    static func directorySize(_ directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            // No .skipsHiddenFiles: dot-prefixed install/backup leftovers
            // occupy real space and must be counted.
            options: []
        ) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            total += fileSize(url)
        }
        return total
    }

    private static func legacyDatabaseSize(_ legacyURL: URL?) -> Int {
        guard let legacyURL else { return 0 }
        return fileSize(legacyURL)
            + fileSize(URL(fileURLWithPath: legacyURL.path + ".wal"))
            + fileSize(URL(fileURLWithPath: legacyURL.path + ".shm"))
    }

    private static func archiveSizes(root: URL) -> (total: Int, perItem: [UUID: Int]) {
        var total = 0
        var perItem = [UUID: Int]()
        for entry in contents(of: root) {
            let size = itemSize(entry)
            total += size
            if let itemID = UUID(uuidString: entry.lastPathComponent) {
                perItem[itemID] = size
            }
        }
        return (total, perItem)
    }

    private static func titledLargestItems(perItem: [UUID: Int]) async throws -> [ItemStorageSize] {
        guard !perItem.isEmpty else { return [] }
        @Dependency(\.stowerRepository)
        var repository
        var titles = [UUID: String]()
        if let library = try? await repository.fetchLibrary(.all) {
            for item in library { titles[item.id] = item.title }
        }
        if let trash = try? await repository.fetchLibrary(.recentlyDeleted) {
            for item in trash { titles[item.id] = item.title }
        }
        return perItem
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { id, bytes in
                ItemStorageSize(id: id, title: titles[id] ?? "Removed item", bytes: bytes)
            }
    }
}

// MARK: - Dependency Key

private enum StorageUsageClientKey: DependencyKey {
    static var liveValue: StorageUsageClient {
        .live(roots: .live())
    }
    static let testValue: StorageUsageClient = .noop
}

extension DependencyValues {
    public var storageUsageClient: StorageUsageClient {
        get { self[StorageUsageClientKey.self] }
        set { self[StorageUsageClientKey.self] = newValue }
    }
}
