import Foundation
import SQLiteData

/// Repository helpers for user-imported website archives (`.webView` items
/// that originated from a `.zip` import rather than a live URL fetch).
///
/// The original zip bytes are persisted in `SavedWebsiteArchiveSyncTable` so
/// SQLiteData's CloudKit bridge can promote them to a CKAsset and every
/// signed-in device sees the item. The unpacked site lives under the
/// per-item `StowerArchive/{itemID}/` directory and is reconstructed on the
/// receiving device by a `hydrateWebsite` ingestion job.
extension StowerRepository {
    static func _saveWebsiteArchive(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID, Data, String, String) async throws -> Void {
        { (itemID: UUID, zipData: Data, sha256: String, originalFilename: String) in
            let now = Date.now
            try await database.write { db in
                try SavedWebsiteArchiveSyncTable
                    .upsert {
                        SavedWebsiteArchiveSyncTable.Draft(
                            id: itemID,
                            zipData: zipData,
                            sha256: sha256,
                            originalFilename: originalFilename,
                            byteCount: zipData.count,
                            createdAt: now,
                            updatedAt: now
                        )
                    }
                    .execute(db)
            }
            scheduleSync()
        }
    }

    static func _loadWebsiteArchive(
        database: any DatabaseWriter
    ) -> @Sendable (UUID) async throws -> WebsiteArchiveBytes? {
        { itemID in
            try await database.read { db in
                guard
                    let row: SavedWebsiteArchiveSyncTable = try SavedWebsiteArchiveSyncTable
                        .find(itemID)
                        .fetchOne(db),
                    !row.zipData.isEmpty
                else {
                    return nil
                }
                return WebsiteArchiveBytes(
                    zipData: row.zipData,
                    originalFilename: row.originalFilename,
                    sha256: row.sha256
                )
            }
        }
    }

    /// Scans the website sync table for rows whose local item has no
    /// unpacked archive on disk and enqueues a `hydrateWebsite` job for
    /// each. Returns the number of jobs enqueued.
    static func _hydrateWebsiteItemsFromSyncedContent(
        database: any DatabaseWriter,
        archiveExists: @escaping @Sendable (UUID) -> Bool
    ) -> @Sendable () async throws -> Int {
        { () async throws -> Int in
            let now = Date.now
            return try await database.write { db -> Int in
                let archiveRows: [SavedWebsiteArchiveSyncTable] =
                    try SavedWebsiteArchiveSyncTable.fetchAll(db)
                var enqueued = 0
                for row in archiveRows {
                    guard row.byteCount > 0 else { continue }
                    // Only enqueue when the item exists and the local archive is missing.
                    guard try SavedItemSyncTable.find(row.id).fetchOne(db) != nil else { continue }
                    if archiveExists(row.id) { continue }

                    let payload = try String(
                        bytes: JSONEncoder().encode(WebsiteHydrationPayload(itemID: row.id)),
                        encoding: .utf8
                    ) ?? ""
                    try IngestionJobLocalTable
                        .insert {
                            IngestionJobLocalTable.Draft(
                                id: UUID(),
                                kind: IngestionJob.Kind.hydrateWebsite.rawValue,
                                payload: payload,
                                createdAt: now,
                                processedAt: nil
                            )
                        }
                        .execute(db)
                    enqueued += 1
                }
                return enqueued
            }
        }
    }
}

/// Return type for `StowerRepository.loadWebsiteArchive`. Carries the raw zip
/// bytes and the original filename so the unpacker can use the latter as a
/// title fallback before parsing `<title>` out of the extracted index.html.
public struct WebsiteArchiveBytes: Sendable, Equatable {
    public let zipData: Data
    public let originalFilename: String
    public let sha256: String

    public init(zipData: Data, originalFilename: String, sha256: String) {
        self.zipData = zipData
        self.originalFilename = originalFilename
        self.sha256 = sha256
    }
}

/// Checks whether an unpacked website archive exists on disk for the given
/// item. URL-ingested archives and zip imports with root `index.html` hit
/// the cheap check first; zip imports with a nested entry (e.g.
/// `guide/index.html`) fall through to a bounded BFS.
///
/// Lives in `StowerData` because the CloudKit hydration path is wired from
/// here and can't reach the feature module's `AssetArchiver` directly. The
/// BFS intentionally mirrors `WebsiteArchiveUnpacker.findEntryURL` so the
/// two places agree on what "archive exists" means.
func websiteArchiveExists(itemID: UUID) -> Bool {
    let docs = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first!
    let archiveDir = docs
        .appendingPathComponent("StowerArchive", isDirectory: true)
        .appendingPathComponent(itemID.uuidString, isDirectory: true)

    let rootIndex = archiveDir.appendingPathComponent("index.html")
    if FileManager.default.fileExists(atPath: rootIndex.path) {
        return true
    }

    // BFS up to 4 directory levels for `index.html`/`index.htm`.
    var queue = [(dir: archiveDir, depth: 0)]
    while !queue.isEmpty {
        let (dir, depth) = queue.removeFirst()
        let children = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children {
            let name = child.lastPathComponent.lowercased()
            if name == "index.html" || name == "index.htm" {
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isDir {
                    return true
                }
            }
        }
        if depth >= 4 {
            continue
        }
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                queue.append((child, depth + 1))
            }
        }
    }
    return false
}
