import Dependencies
import Foundation
import SQLiteData

extension StowerRepository {
    /// Books sync as their original EPUB file in the asset store. This finds
    /// synced `epub` manifests whose item has nothing to render on this
    /// device yet and enqueues a `downloadAsset` job for each, which
    /// downloads the file and imports it locally. Returns the number of jobs
    /// enqueued.
    static func _hydrateBookItemsFromSyncedContent(
        database: any DatabaseWriter
    ) -> @Sendable () async throws -> Int {
        { () async throws -> Int in
            @Dependency(\.date.now)
            var now
            @Dependency(\.uuid)
            var uuid

            // Scan in a read and take the write lock only when a book is
            // actually missing, which after the first sync is never.
            let pending: [UUID] = try await database.read { db in
                let bookItemIDs = try SavedAssetManifestSyncTable
                    .where { $0.kind.eq(CloudAssetKind.epub.rawValue) }
                    .select(\.itemID)
                    .fetchAll(db)
                guard !bookItemIDs.isEmpty else { return [] }
                let liveIDs = Set(
                    try SavedItemSyncTable
                        .where { $0.id.in(bookItemIDs) }
                        .where { $0.deletedAt.is(nil) }
                        .select(\.id)
                        .fetchAll(db)
                )
                let renderable = Set(
                    try SavedItemContentLocalTable
                        .where { $0.itemID.in(bookItemIDs) }
                        .where { $0.documentJSON.neq("") }
                        .select(\.itemID)
                        .fetchAll(db)
                )
                let offloaded = Set(
                    try ItemStorageLocalTable
                        .where { $0.itemID.in(bookItemIDs) }
                        .where { $0.offloadedAt.isNot(nil) }
                        .select(\.itemID)
                        .fetchAll(db)
                )
                return bookItemIDs.filter {
                    liveIDs.contains($0) && !renderable.contains($0) && !offloaded.contains($0)
                }
            }
            guard !pending.isEmpty else { return 0 }

            return try await database.write { db -> Int in
                var enqueued = 0
                for itemID in pending {
                    let existingJob = try IngestionJobLocalTable
                        .where { $0.kind.eq(IngestionJob.Kind.downloadAsset.rawValue) }
                        .where { $0.payload.like("%\(itemID.uuidString)%") }
                        .where { $0.processedAt.is(nil) }
                        .fetchCount(db)
                    guard existingJob == 0 else { continue }

                    let hasContentRow = try SavedItemContentLocalTable
                        .where { $0.itemID.eq(itemID) }
                        .fetchCount(db) > 0
                    if !hasContentRow {
                        try SavedItemContentLocalTable
                            .insert {
                                SavedItemContentLocalTable.Draft(
                                    itemID: itemID,
                                    renderFormat: RenderFormat.structuredV1.rawValue,
                                    documentVersion: 1,
                                    plainText: "",
                                    documentJSON: "",
                                    sourceHTMLHash: "",
                                    sourceHTML: "",
                                    localStatus: "notDownloaded",
                                    localError: nil,
                                    createdAt: now,
                                    updatedAt: now
                                )
                            }
                            .execute(db)
                    }

                    let payload = try AssetJobPayload(itemID: itemID, kind: .epub).encoded()
                    try IngestionJobLocalTable
                        .insert {
                            IngestionJobLocalTable.Draft(
                                id: uuid(),
                                kind: IngestionJob.Kind.downloadAsset.rawValue,
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
