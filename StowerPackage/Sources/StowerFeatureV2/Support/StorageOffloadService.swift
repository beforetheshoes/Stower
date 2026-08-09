import Dependencies
import Foundation
import OSLog
import StowerData

private let kOffloadLogger = Logger(subsystem: "com.ryanleewilliams.stower", category: "StorageOffload")

public enum StorageOffloadError: Error, Equatable, LocalizedError {
    case notOffloadable

    public var errorDescription: String? {
        "This item can't be removed from the device until its iCloud copy is confirmed."
    }
}

/// Local eviction ("offload") of heavy per-item content whose bytes are
/// safely stored elsewhere, and the automatic budget-based pass over read
/// items. Regular articles are never offloaded — per the product policy their
/// reader content always stays local.
public enum StorageOffloadService {
    /// Whether the item's heavy local files can be deleted without losing the
    /// only copy. This is the safety gate shared by manual and automatic
    /// offload:
    /// - PDFs and website imports need a confirmed (`uploaded`) asset
    ///   manifest.
    /// - Interactive web captures need their capture manifest — the chunk
    ///   rows in the local database rebuild the archive, even offline.
    public static func canOffload(_ info: ItemStorageInfo) -> Bool {
        guard info.offloadedAt == nil else { return false }
        switch info.renderFormat {
        case "pdf":
            return info.uploadState == "uploaded"
                && info.assetManifests.contains { $0.kind == .pdf }
        case "webView":
            if info.assetManifests.contains(where: { $0.kind == .websiteZip }) {
                return info.uploadState == "uploaded"
            }
            // Interactive URL articles reinstall from local capture chunks.
            return info.hasCaptureManifest
        default:
            return false
        }
    }

    /// Automatic eviction additionally requires the item to be read and not
    /// pinned. Manual offload only requires safety.
    public static func isAutoEvictable(_ info: ItemStorageInfo) -> Bool {
        info.isRead && !info.isPinned && canOffload(info)
    }

    /// Deletes the item's local heavy files and marks it offloaded. The
    /// caller is responsible for the eligibility check (`canOffload`).
    public static func offload(itemID: UUID, repository: StowerRepository) async throws {
        @Dependency(\.itemStorageClient)
        var itemStorageClient

        guard let info = try await itemStorageClient.storageInfo(itemID), canOffload(info) else {
            throw StorageOffloadError.notOffloadable
        }
        AssetArchiver.deleteArchive(for: itemID)
        try await repository.updateLocalContentStatus(itemID, "notDownloaded", nil)
        try await itemStorageClient.setOffloaded(itemID, true)
        kOffloadLogger.info("Offloaded \(itemID, privacy: .public)")
    }

    /// Result of an automatic or bulk eviction pass.
    public struct EvictionReport: Equatable, Sendable {
        public var evictedCount = 0
        public var freedBytes = 0

        public init(evictedCount: Int = 0, freedBytes: Int = 0) {
            self.evictedCount = evictedCount
            self.freedBytes = freedBytes
        }
    }

    /// Evicts read, unpinned, safely-offloadable items — least recently
    /// opened first — until the archive directory fits the configured budget.
    /// No budget (nil) disables the pass; `budgetOverride` of 0 evicts every
    /// eligible item ("Offload Read Items Now").
    @discardableResult
    public static func runEviction(
        repository: StowerRepository,
        excluding excludedItemIDs: Set<UUID> = [],
        budgetOverride: Int? = nil
    ) async throws -> EvictionReport {
        @Dependency(\.itemStorageClient)
        var itemStorageClient
        @Dependency(\.cloudAssetClient)
        var cloudAssetClient

        let configuredBudget = try await itemStorageClient.budgetBytes()
        guard let budget = budgetOverride ?? configuredBudget else {
            return EvictionReport()
        }

        let candidates = try await itemStorageClient.evictionCandidates()
            .filter { isAutoEvictable($0) && !excludedItemIDs.contains($0.itemID) }

        var sized: [(info: ItemStorageInfo, bytes: Int)] = candidates.map { info in
            (info, archiveDirectorySize(for: info.itemID))
        }
        .filter { $0.bytes > 0 }
        // Least recently opened first; never-opened items lead the line.
        sized.sort { lhs, rhs in
            (lhs.info.lastOpenedAt ?? .distantPast) < (rhs.info.lastOpenedAt ?? .distantPast)
        }

        var occupiedBytes = totalArchiveBytes()
        var report = EvictionReport()
        for (info, bytes) in sized {
            guard occupiedBytes > budget else { break }
            // Belt and suspenders for asset-backed items: confirm the iCloud
            // record is actually there before deleting the local copy. An
            // interactive capture restores from local chunks, so it needs no
            // network check.
            if let manifest = info.assetManifests.first {
                guard (try? await cloudAssetClient.exists(manifest.recordName)) == true else {
                    continue
                }
            }
            do {
                try await offload(itemID: info.itemID, repository: repository)
            } catch {
                continue
            }
            occupiedBytes -= bytes
            report.evictedCount += 1
            report.freedBytes += bytes
        }
        if report.evictedCount > 0 {
            kOffloadLogger.info(
                "Eviction pass freed \(report.freedBytes) bytes across \(report.evictedCount) items"
            )
        }
        return report
    }

    private static func totalArchiveBytes() -> Int {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let root = documents.appendingPathComponent("StowerArchive", isDirectory: true)
        return StorageScanActor.directorySize(root)
    }

    private static func archiveDirectorySize(for itemID: UUID) -> Int {
        StorageScanActor.directorySize(AssetArchiver.archiveDirectory(for: itemID))
    }
}
