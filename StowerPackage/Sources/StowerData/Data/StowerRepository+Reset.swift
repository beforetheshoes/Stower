import Foundation
import SQLiteData

extension StowerRepository {
    /// Empties every local-only table in one transaction.
    ///
    /// This used to be a hand-written list of `DELETE` statements in the app
    /// reducer, and it had fallen behind the schema: summaries, the orphan
    /// quarantine, per-item storage state and the storage policy all survived
    /// a reset. Keeping it beside the tables — and covered by a test that
    /// compares it with the schema — is what stops that happening again.
    static func _resetLocalData(database: any DatabaseWriter) -> @Sendable () async throws -> Void {
        {
            try await database.write { db in
                try SavedItemContentLocalTable.delete().execute(db)
                try ArticleSummaryLocalTable.delete().execute(db)
                try SavedMediaLocalTable.delete().execute(db)
                try SavedEmbedLocalTable.delete().execute(db)
                try SavedImageRefLocalTable.delete().execute(db)
                try SavedImageAssetLocalTable.delete().execute(db)
                try ImageDownloadSettingsLocalTable.delete().execute(db)
                try ReaderAppearanceSettingsLocalTable.delete().execute(db)
                try IngestionJobLocalTable.delete().execute(db)
                try ItemStorageLocalTable.delete().execute(db)
                try StoragePolicyLocalTable.delete().execute(db)
                try OrphanCandidateLocalTable.delete().execute(db)
            }
        }
    }
}
