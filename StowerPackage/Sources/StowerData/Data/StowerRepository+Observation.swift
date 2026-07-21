import Foundation
import GRDB
import SQLiteData

extension StowerRepository {
    static func _observeLibraryChanges(
        database: any DatabaseWriter
    ) -> @Sendable () -> AsyncStream<Void> {
        {
            let observation = ValueObservation.trackingConstantRegion { db in
                [
                    try SavedItemSyncTable.fetchCount(db),
                    try TagSyncTable.fetchCount(db),
                    try ItemTagSyncTable.fetchCount(db),
                ]
            }

            return AsyncStream { continuation in
                let task = Task {
                    do {
                        for try await _ in observation.values(in: database) {
                            continuation.yield(())
                        }
                    } catch {
                        // A later explicit reload remains available if an
                        // observation is interrupted by a database reset.
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}
