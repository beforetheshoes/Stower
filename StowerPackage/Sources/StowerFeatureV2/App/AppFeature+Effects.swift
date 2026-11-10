import ComposableArchitecture
import Foundation
import StowerData

// The long-running effects `AppFeature` starts: startup maintenance, the
// post-sync follow-up, queue drains, and reader navigation.
extension AppFeature {
    /// The database half of startup: reconcile, backfill, hydrate, drain the
    /// ingestion queue, then the age-gated storage work. Idempotent, and
    /// cancelled when the scene enters the background — see
    /// `sceneDidEnterBackground`.
    func startupMaintenance(state: State) -> EffectOf<Self> {
        let cloudSyncClient = self.cloudSyncClient
        let repository = self.repository
        let ingestionClient = self.ingestionClient
        let pdfIngestionClient = self.pdfIngestionClient
        let textIngestionClient = self.textIngestionClient
        let date = self.date
        let ingestionCoordinator = self.ingestionCoordinator
        let storageUsageClient = self.storageUsageClient
        let openReaderItemID = state.reader?.itemID
        return .run { send in
            do {
                _ = try await repository.reconcileOrphanedTagAssignments()
                // Backfill the text sync table from local content
                // for any text items missing a sync row (recovery
                // from the v11 DROP TABLE migration or items that
                // predate the sync table).
                _ = try await repository.backfillTextSyncTable()
                _ = try await repository.enqueueHydrationJobsForMissingContent()
                try await ingestionCoordinator.run {
                    try await processIngestionJobs(
                        repository: repository,
                        ingestionClient: ingestionClient,
                        pdfIngestionClient: pdfIngestionClient,
                        textIngestionClient: textIngestionClient,
                        ingestionCoordinator: ingestionCoordinator
                    ) { date.now }
                }
                await send(.failedImportsLoaded(
                    FailedImport.list(from: try await repository.fetchFailedIngestionJobs())
                ))
                // Best effort: the coordinator reports sync
                // problems through the status stream, and a
                // failed push is not a failed launch.
                try? await cloudSyncClient.sendChanges()
                await send(.startupFinished)
                await send(.settings(.load))
                // Finished jobs are never read again; drop week-old ones.
                _ = try? await repository.pruneProcessedIngestionJobs(
                    date.now.addingTimeInterval(-7 * 24 * 3600)
                )
                // Storage maintenance runs last so it never delays
                // startup, and only every few days. Sweeps are
                // age-gated and the orphan sweep quarantines for a
                // week before deleting, so running shortly after a
                // fresh install is safe.
                let defaults = UserDefaults.standard
                let lastMaintenance = defaults.object(
                    forKey: "lastStorageMaintenanceDate"
                ) as? Date
                let isDue = lastMaintenance
                    .map { date.now.timeIntervalSince($0) >= 3 * 24 * 3600 } ?? true
                if isDue {
                    _ = try? await storageUsageClient.runMaintenance(.periodic)
                    defaults.set(date.now, forKey: "lastStorageMaintenanceDate")
                }
                // Cloud-asset backfill: upload PDFs that predate
                // the asset store and (past the gate date) migrate
                // legacy website zips; then run the budget-based
                // eviction pass. All idempotent and cheap when
                // there is nothing to do.
                if (try? await CloudAssetService.enqueueBackfillJobs(repository: repository)) ?? 0 > 0 {
                    try? await ingestionCoordinator.run {
                        try await processIngestionJobs(
                            repository: repository,
                            ingestionClient: ingestionClient,
                            pdfIngestionClient: pdfIngestionClient,
                            textIngestionClient: textIngestionClient,
                            ingestionCoordinator: ingestionCoordinator
                        ) { date.now }
                    }
                }
                _ = try? await StorageOffloadService.runEviction(
                    repository: repository,
                    excluding: Set([openReaderItemID].compactMap(\.self))
                )
            } catch where error.isDatabaseSuspension {
                // Backgrounded mid-startup; re-runs on activation.
                await send(.startupMaintenanceInterrupted)
            } catch {
                await send(.startupFailed(error.localizedDescription))
            }
        }
        .cancellable(id: CancelID.startupMaintenance, cancelInFlight: true)
    }

    /// Hydrates content for records that just arrived through CloudKit and
    /// drains anything the share extension queued.
    func syncFollowUp() -> EffectOf<Self> {
        let repository = self.repository
        let ingestionClient = self.ingestionClient
        let pdfIngestionClient = self.pdfIngestionClient
        let textIngestionClient = self.textIngestionClient
        let date = self.date
        let ingestionCoordinator = self.ingestionCoordinator
        return .run { send in
            // Each scan is independent: one failing must not stop the rest.
            // A scan refused because the database is suspended is different —
            // the whole pass is repeated on the next activation.
            let scans: [@Sendable () async throws -> Int] = [
                repository.enqueueHydrationJobsForMissingContent,
                repository.hydratePDFItemsFromSyncedContent,
                repository.hydrateTextItemsFromSyncedContent,
                repository.hydrateWebsiteItemsFromSyncedContent,
                repository.hydrateBookItemsFromSyncedContent,
                repository.reconcileOrphanedTagAssignments,
            ]
            for scan in scans {
                do {
                    _ = try await scan()
                } catch where error.isDatabaseSuspension {
                    await send(.syncFollowUpInterrupted)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    reportIssue(error)
                }
            }
            try? await ingestionCoordinator.run {
                try await processIngestionJobs(
                    repository: repository,
                    ingestionClient: ingestionClient,
                    pdfIngestionClient: pdfIngestionClient,
                    textIngestionClient: textIngestionClient,
                    ingestionCoordinator: ingestionCoordinator
                ) { date.now }
            }
            let jobs = (try? await repository.fetchFailedIngestionJobs()) ?? []
            await send(.failedImportsLoaded(FailedImport.list(from: jobs)))
            await send(.syncFollowUpFinished)
        }
        .cancellable(id: CancelID.syncFollowUp, cancelInFlight: true)
    }

    /// Drains the ingestion queue and refreshes the failed-import list.
    ///
    /// Cancelled when the scene enters the background (see
    /// `sceneDidEnterBackground`); every activation starts a fresh drain, so
    /// whatever was cut short runs again then.
    func drainIngestionQueue(
        state: inout State,
        retryingFailed: Bool = false
    ) -> EffectOf<Self> {
        state.activeDrainCount += 1
        let repository = self.repository
        let ingestionClient = self.ingestionClient
        let pdfIngestionClient = self.pdfIngestionClient
        let textIngestionClient = self.textIngestionClient
        let date = self.date
        let ingestionCoordinator = self.ingestionCoordinator
        return .run { send in
            if retryingFailed {
                try? await repository.retryFailedIngestionJobs()
            }
            try? await ingestionCoordinator.run {
                try await processIngestionJobs(
                    repository: repository,
                    ingestionClient: ingestionClient,
                    pdfIngestionClient: pdfIngestionClient,
                    textIngestionClient: textIngestionClient,
                    ingestionCoordinator: ingestionCoordinator
                ) { date.now }
            }
            let jobs = (try? await repository.fetchFailedIngestionJobs()) ?? []
            await send(.failedImportsLoaded(FailedImport.list(from: jobs)))
            await send(.ingestionDrainFinished)
        }
        .cancellable(id: CancelID.ingestionDrain)
    }

    func navigateReader(
        offset: Int,
        state: inout State
    ) -> EffectOf<Self> {
        guard let targetID = state.readerNavigationTarget(offset: offset) else { return .none }
        state.library.openItemID = targetID

        // Prefer the observed row so the header renders instantly; fall
        // back to a database load when the target has left the current list.
        if let item = state.library.items.first(where: { $0.id == targetID }) {
            state.reader = ReaderFeature.State(item: item, appearance: state.cachedAppearance)
        } else {
            state.reader = ReaderFeature.State(itemID: targetID, appearance: state.cachedAppearance)
        }
        let itemStorageClient = self.itemStorageClient
        return .run { _ in
            try? await itemStorageClient.touchOpened(targetID)
        }
    }
}
