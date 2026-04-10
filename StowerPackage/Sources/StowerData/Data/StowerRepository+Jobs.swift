import Foundation
import SQLiteData

extension StowerRepository {
    static func _enqueueIngestionJob(database: any DatabaseWriter) -> @Sendable (IngestionJob.Kind, String) async throws -> Void {
        { (kind: IngestionJob.Kind, payload: String) async throws -> Void in
            try await database.write { db -> Void in
                try IngestionJobLocalTable.insert {
                    IngestionJobLocalTable.Draft(
                        id: UUID(),
                        kind: kind.rawValue,
                        payload: payload,
                        createdAt: .now,
                        processedAt: nil
                    )
                }.execute(db)
            }
        }
    }

    static func _fetchPendingIngestionJobs(database: any DatabaseWriter) -> @Sendable () async throws -> [IngestionJob] {
        { () async throws -> [IngestionJob] in
            try await database.read { db -> [IngestionJob] in
                let rows: [IngestionJobLocalTable] = try IngestionJobLocalTable
                    .where { $0.processedAt.is(nil) }
                    .order { $0.createdAt }
                    .fetchAll(db)
                return rows.compactMap { row -> IngestionJob? in
                    guard let kind = IngestionJob.Kind(rawValue: row.kind) else { return nil }
                    return IngestionJob(id: row.id, kind: kind, payload: row.payload, createdAt: row.createdAt)
                }
            }
        }
    }

    static func _markIngestionJobProcessed(database: any DatabaseWriter) -> @Sendable (UUID) async throws -> Void {
        { (id: UUID) async throws -> Void in
            try await database.write { db -> Void in
                try IngestionJobLocalTable.find(id).update {
                    $0.processedAt = #bind(Date.now as Date?)
                }.execute(db)
            }
        }
    }

    static func _enqueueHydrationJobsForMissingContent(database: any DatabaseWriter) -> @Sendable () async throws -> Int {
        { () async throws -> Int in
            let now: Date = Date.now
            return try await database.write { db -> Int in
                let synced: [SavedItemSyncTable] = try SavedItemSyncTable
                    .where { !$0.isArchived }
                    .fetchAll(db)
                let locals: [SavedItemContentLocalTable] = try SavedItemContentLocalTable.fetchAll(db)
                let localIDs: Set<UUID> = Set(locals.map(\.itemID))

                var enqueued = 0
                for item in synced {
                    guard !localIDs.contains(item.id) else { continue }
                    guard let url = item.sourceURL, !url.isEmpty else { continue }

                    try SavedItemContentLocalTable.insert {
                        SavedItemContentLocalTable.Draft(
                            itemID: item.id,
                            renderFormat: "structuredV1",
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
                    }.execute(db)

                    let payload: String = try String(
                        decoding: JSONEncoder().encode(HydrationPayload(itemID: item.id, url: url)),
                        as: UTF8.self
                    )
                    try IngestionJobLocalTable.insert {
                        IngestionJobLocalTable.Draft(
                            id: UUID(),
                            kind: IngestionJob.Kind.hydrate.rawValue,
                            payload: payload,
                            createdAt: now,
                            processedAt: nil
                        )
                    }.execute(db)
                    enqueued += 1
                }
                return enqueued
            }
        }
    }
}
