import CryptoKit
import Dependencies
import Foundation
import SQLiteData

public struct StowerRepository: Sendable {
    public var fetchLibrary: @Sendable (LibraryFilter) async throws -> [SavedItem]
    public var loadItem: @Sendable (UUID) async throws -> SavedItem?
    public var createItemFromIngestion: @Sendable (IngestionResult) async throws -> SavedItem
    public var updateItemFromIngestion: @Sendable (UUID, IngestionResult) async throws -> SavedItem?
    public var hydrateItemContent: @Sendable (UUID, IngestionResult) async throws -> Void
    public var updateLocalContentStatus: @Sendable (UUID, String, String?) async throws -> Void
    public var loadReaderDocument: @Sendable (UUID) async throws -> ReaderDocument?
    public var saveReaderDocument: @Sendable (UUID, ReaderDocument, String) async throws -> Void
    public var loadSourceHTML: @Sendable (UUID) async throws -> String?
    public var upsertMedia: @Sendable ([MediaDescriptor], UUID) async throws -> Void
    /// Loads the cached AI summary for an item, if one has been generated. Nil
    /// means no summary has been persisted yet (or the item isn't in the DB).
    public var loadSummary: @Sendable (UUID) async throws -> CachedSummary?
    /// Persists an AI summary to the local-only content table. Overwrites any
    /// prior summary for the same item.
    public var saveSummary: @Sendable (_ itemID: UUID, _ text: String) async throws -> Void
    /// Soft-deletes an item (moves it to the Recently Deleted list).
    /// Retained for backwards compatibility with all existing call sites.
    public var deleteItem: @Sendable (UUID) async throws -> Void
    /// Persist the last-read block index for an item (scroll position restoration).
    public var saveReadingProgress: @Sendable (_ itemID: UUID, _ blockIndex: Int) async throws -> Void

    // MARK: - List/filter + bucket mutations
    public var setReadStatus: @Sendable (UUID, Bool) async throws -> Void
    public var setStarred: @Sendable (UUID, Bool) async throws -> Void
    public var restoreFromTrash: @Sendable (UUID) async throws -> Void
    /// Hard delete + remove asset archive. Use from the Recently Deleted list.
    public var permanentlyDelete: @Sendable (UUID) async throws -> Void
    /// Deletes trash items older than the retention window; returns the purged IDs.
    public var purgeOldTrash: @Sendable () async throws -> [UUID]
    public var fetchListCounts: @Sendable () async throws -> LibraryListCounts

    // MARK: - Tags
    public var fetchTags: @Sendable () async throws -> [Tag]
    public var fetchTagIDs: @Sendable (UUID) async throws -> [UUID]
    public var createTag: @Sendable (String, String?) async throws -> Tag
    public var renameTag: @Sendable (UUID, String) async throws -> Void
    public var deleteTag: @Sendable (UUID) async throws -> Void
    public var addTag: @Sendable (UUID, UUID) async throws -> Void
    public var removeTag: @Sendable (UUID, UUID) async throws -> Void

    /// Ping stream fired after any library mutation. Sidebar + library screens
    /// subscribe to reload counts/rows without explicit callback plumbing.
    public var observeLibraryChanges: @Sendable () -> AsyncStream<Void>

    public var loadSettings: @Sendable () async throws -> ImageDownloadSettings
    public var saveSettings: @Sendable (ImageDownloadSettings) async throws -> Void
    public var loadReaderAppearanceSettings: @Sendable () async throws -> ReaderAppearanceSettings
    public var saveReaderAppearanceSettings: @Sendable (ReaderAppearanceSettings) async throws -> Void

    public var enqueueIngestionJob: @Sendable (IngestionJob.Kind, String) async throws -> Void
    public var fetchPendingIngestionJobs: @Sendable () async throws -> [IngestionJob]
    public var markIngestionJobProcessed: @Sendable (UUID) async throws -> Void

    public var enqueueHydrationJobsForMissingContent: @Sendable () async throws -> Int
    /// Populates the local content table for PDF items that arrived via
    /// CloudKit sync. See `_hydratePDFItemsFromSyncedContent` for details.
    /// Returns the number of items hydrated.
    public var hydratePDFItemsFromSyncedContent: @Sendable () async throws -> Int
}

private enum StowerRepositoryKey: DependencyKey {
    static let liveValue: StowerRepository = .failing
    static let testValue: StowerRepository = .failing
}

extension DependencyValues {
    public var stowerRepository: StowerRepository {
        get { self[StowerRepositoryKey.self] }
        set { self[StowerRepositoryKey.self] = newValue }
    }
}

public enum RepositoryError: Error {
    case notBootstrapped
}

// MARK: - Failing

extension StowerRepository {
    static let failing: StowerRepository = {
        StowerRepository(
            fetchLibrary: { _ in [] },
            loadItem: { _ in nil },
            createItemFromIngestion: { _ in throw RepositoryError.notBootstrapped },
            updateItemFromIngestion: { _, _ in nil },
            hydrateItemContent: { _, _ in },
            updateLocalContentStatus: { _, _, _ in },
            loadReaderDocument: { _ in nil },
            saveReaderDocument: { _, _, _ in },
            loadSourceHTML: { _ in nil },
            upsertMedia: { _, _ in },
            loadSummary: { _ in nil },
            saveSummary: { _, _ in },
            deleteItem: { _ in },
            saveReadingProgress: { _, _ in },
            setReadStatus: { _, _ in },
            setStarred: { _, _ in },
            restoreFromTrash: { _ in },
            permanentlyDelete: { _ in },
            purgeOldTrash: { [] },
            fetchListCounts: { .zero },
            fetchTags: { [] },
            fetchTagIDs: { _ in [] },
            createTag: { name, _ in Tag(name: name) },
            renameTag: { _, _ in },
            deleteTag: { _ in },
            addTag: { _, _ in },
            removeTag: { _, _ in },
            observeLibraryChanges: { AsyncStream { _ in } },
            loadSettings: { ImageDownloadSettings() },
            saveSettings: { _ in },
            loadReaderAppearanceSettings: { ReaderAppearanceSettings() },
            saveReaderAppearanceSettings: { _ in },
            enqueueIngestionJob: { _, _ in },
            fetchPendingIngestionJobs: { [] },
            markIngestionJobProcessed: { _ in },
            enqueueHydrationJobsForMissingContent: { 0 },
            hydratePDFItemsFromSyncedContent: { 0 }
        )
    }()
}

// MARK: - Live (assembly only — each operation is in its own file)

extension StowerRepository {
    static func live(
        database: any DatabaseWriter,
        cloudSyncClient: CloudSyncClient
    ) -> Self {
        // Broadcast for the library-change stream. Every mutation closure pings
        // this; sidebar + library screens subscribe to refresh counts/rows.
        let changeBroadcast = LibraryChangeBroadcast()

        let scheduleSync: @Sendable () -> Void = {
            Task { await cloudSyncClient.scheduleSendChanges() }
        }
        let scheduleSyncAndNotify: @Sendable () -> Void = {
            scheduleSync()
            changeBroadcast.ping()
        }

        // In-memory LRU cache shared across the live repository's closures so
        // opening a previously-read article skips the JSON decode.
        let documentCache = ReaderDocumentCache()

        let baseLoadDocument = _loadReaderDocument(database: database)
        let cachedLoadDocument: @Sendable (UUID) async throws -> ReaderDocument? = { id in
            if let cached = documentCache.get(id) {
                return cached
            }
            let document = try await baseLoadDocument(id)
            if let document { documentCache.set(id, document: document) }
            return document
        }

        let baseSaveDocument = _saveReaderDocument(database: database)
        let cachedSaveDocument: @Sendable (UUID, ReaderDocument, String) async throws -> Void = { id, document, html in
            try await baseSaveDocument(id, document, html)
            documentCache.set(id, document: document)
        }

        let baseUpdateFromIngestion = _updateItemFromIngestion(database: database, scheduleSync: scheduleSyncAndNotify)
        let cachedUpdateFromIngestion: @Sendable (UUID, IngestionResult) async throws -> SavedItem? = { id, result in
            documentCache.invalidate(id)
            return try await baseUpdateFromIngestion(id, result)
        }

        // `createItemFromIngestion` uses `stableItemID(from: url)` to derive a
        // deterministic item UUID — re-ingesting the same URL writes a fresh
        // document under the same key. The reader's in-memory cache must be
        // invalidated for that key BEFORE the create runs, otherwise a stale
        // document from a prior open of the same item silently overrides the
        // new content. Same applies to hydration of CloudKit-synced items.
        let baseCreateFromIngestion = _createItemFromIngestion(database: database, scheduleSync: scheduleSyncAndNotify)
        let cachedCreateFromIngestion: @Sendable (IngestionResult) async throws -> SavedItem = { result in
            let id = stableItemID(from: result.canonicalURL ?? result.sourceURL)
            documentCache.invalidate(id)
            return try await baseCreateFromIngestion(result)
        }

        let baseHydrateItemContent = _hydrateItemContent(database: database)
        let cachedHydrateItemContent: @Sendable (UUID, IngestionResult) async throws -> Void = { id, result in
            documentCache.invalidate(id)
            try await baseHydrateItemContent(id, result)
        }

        // `deleteItem` now soft-deletes. The document cache stays valid
        // because the item may be restored from trash before being purged.
        let softDelete = _softDeleteItem(database: database, scheduleSync: scheduleSyncAndNotify)
        let cachedDeleteItem: @Sendable (UUID) async throws -> Void = { id in
            try await softDelete(id)
        }

        // Hard-delete path also invalidates the reader cache.
        let rawPermanentDelete = _permanentlyDelete(database: database, scheduleSync: scheduleSyncAndNotify)
        let cachedPermanentDelete: @Sendable (UUID) async throws -> Void = { id in
            documentCache.invalidate(id)
            try await rawPermanentDelete(id)
        }

        return Self(
            fetchLibrary: _fetchLibraryFiltered(database: database),
            loadItem: _loadItem(database: database),
            createItemFromIngestion: _createItemFromIngestionWithNotify(
                base: cachedCreateFromIngestion,
                broadcast: changeBroadcast
            ),
            updateItemFromIngestion: cachedUpdateFromIngestion,
            hydrateItemContent: cachedHydrateItemContent,
            updateLocalContentStatus: _updateLocalContentStatus(database: database),
            loadReaderDocument: cachedLoadDocument,
            saveReaderDocument: cachedSaveDocument,
            loadSourceHTML: _loadSourceHTML(database: database),
            upsertMedia: _upsertMedia(database: database),
            loadSummary: _loadSummary(database: database),
            saveSummary: _saveSummary(database: database),
            deleteItem: cachedDeleteItem,
            saveReadingProgress: _saveReadingProgress(database: database, scheduleSync: scheduleSync),
            setReadStatus: _setReadStatus(database: database, scheduleSync: scheduleSyncAndNotify),
            setStarred: _setStarred(database: database, scheduleSync: scheduleSyncAndNotify),
            restoreFromTrash: _restoreFromTrash(database: database, scheduleSync: scheduleSyncAndNotify),
            permanentlyDelete: cachedPermanentDelete,
            purgeOldTrash: _purgeOldTrash(database: database, scheduleSync: scheduleSyncAndNotify),
            fetchListCounts: _fetchListCounts(database: database),
            fetchTags: _fetchTags(database: database),
            fetchTagIDs: _fetchTagIDs(database: database),
            createTag: _createTag(database: database, scheduleSync: scheduleSyncAndNotify),
            renameTag: _renameTag(database: database, scheduleSync: scheduleSyncAndNotify),
            deleteTag: _deleteTag(database: database, scheduleSync: scheduleSyncAndNotify),
            addTag: _addTag(database: database, scheduleSync: scheduleSyncAndNotify),
            removeTag: _removeTag(database: database, scheduleSync: scheduleSyncAndNotify),
            observeLibraryChanges: { changeBroadcast.stream() },
            loadSettings: _loadSettings(database: database),
            saveSettings: _saveSettings(database: database),
            loadReaderAppearanceSettings: _loadReaderAppearanceSettings(database: database),
            saveReaderAppearanceSettings: _saveReaderAppearanceSettings(database: database),
            enqueueIngestionJob: _enqueueIngestionJob(database: database),
            fetchPendingIngestionJobs: _fetchPendingIngestionJobs(database: database),
            markIngestionJobProcessed: _markIngestionJobProcessed(database: database),
            enqueueHydrationJobsForMissingContent: _enqueueHydrationJobsForMissingContent(database: database),
            hydratePDFItemsFromSyncedContent: _hydratePDFItemsFromSyncedContent(database: database)
        )
    }

    /// Wraps the create-ingestion closure so a successful create also pings
    /// the library-change broadcast (inserts show up in sidebar counts).
    private static func _createItemFromIngestionWithNotify(
        base: @escaping @Sendable (IngestionResult) async throws -> SavedItem,
        broadcast: LibraryChangeBroadcast
    ) -> @Sendable (IngestionResult) async throws -> SavedItem {
        { result in
            let item = try await base(result)
            broadcast.ping()
            return item
        }
    }
}

// MARK: - Library change broadcast

/// Thread-safe fan-out of "the library just changed" notifications.
/// Mutation closures call `ping()`; consumers subscribe via `stream()`.
final class LibraryChangeBroadcast: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:] // swiftlint:disable:this prefer_let_over_var

    func stream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    func ping() {
        lock.lock()
        let all = Array(continuations.values)
        lock.unlock()
        for c in all { c.yield(()) }
    }
}
