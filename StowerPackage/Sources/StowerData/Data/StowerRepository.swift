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
    public var loadEditableTextSource: @Sendable (UUID) async throws -> EditableTextSource?
    public var saveReaderDocument: @Sendable (UUID, ReaderDocument, String) async throws -> Void
    public var saveEditedTextSource: @Sendable (UUID, IngestionResult) async throws -> SavedItem?
    public var loadSourceHTML: @Sendable (UUID) async throws -> String?
    public var saveArticleCapture: @Sendable (WebCaptureManifest, [WebCaptureChunk]) async throws -> Void
    public var loadArticleCapture: @Sendable (UUID) async throws -> SyncedWebCapture?
    public var markArticleCaptureInstalled: @Sendable (UUID, UUID, Int) async throws -> Void
    public var upsertMedia: @Sendable ([MediaDescriptor], UUID) async throws -> Void
    /// Loads a summary only when its quality, prompt version, and current
    /// article contents all match the cached entry.
    public var loadSummary: @Sendable (
        _ itemID: UUID,
        _ quality: String,
        _ promptVersion: Int
    ) async throws -> CachedSummary?
    /// Persists one versioned summary per quality for an article.
    public var saveSummary: @Sendable (
        _ itemID: UUID,
        _ quality: String,
        _ promptVersion: Int,
        _ text: String
    ) async throws -> Void
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
    public var fetchTagIDsByItem: @Sendable ([UUID]) async throws -> [UUID: [UUID]]
    public var createTag: @Sendable (String, String?) async throws -> Tag
    public var renameTag: @Sendable (UUID, String) async throws -> Void
    public var deleteTag: @Sendable (UUID) async throws -> Void
    public var addTag: @Sendable (UUID, UUID) async throws -> Void
    public var removeTag: @Sendable (UUID, UUID) async throws -> Void
    public var reconcileOrphanedTagAssignments: @Sendable () async throws -> Int

    /// Database-backed stream fired whenever library, tag, or assignment rows
    /// change locally or through CloudKit.
    public var observeLibraryChanges: @Sendable () -> AsyncStream<Void>

    public var loadSettings: @Sendable () async throws -> ImageDownloadSettings
    public var saveSettings: @Sendable (ImageDownloadSettings) async throws -> Void
    public var loadReaderAppearanceSettings: @Sendable () async throws -> ReaderAppearanceSettings
    public var saveReaderAppearanceSettings: @Sendable (ReaderAppearanceSettings) async throws -> Void

    public var enqueueIngestionJob: @Sendable (IngestionJob.Kind, String) async throws -> Void
    public var claimNextIngestionJob: @Sendable (Date) async throws -> IngestionJob?
    public var claimNextIngestionJobOfKind: @Sendable (IngestionJob.Kind, Date) async throws -> IngestionJob?
    public var completeIngestionJob: @Sendable (UUID, Date) async throws -> Void
    public var failIngestionJob: @Sendable (UUID, String, Date) async throws -> Void
    public var fetchFailedIngestionJobs: @Sendable () async throws -> [IngestionJob]
    public var retryFailedIngestionJobs: @Sendable () async throws -> Void
    public var dismissFailedIngestionJobs: @Sendable (Date) async throws -> Void

    public var enqueueHydrationJobsForMissingContent: @Sendable () async throws -> Int
    /// Populates the local content table for PDF items that arrived via
    /// CloudKit sync. See `_hydratePDFItemsFromSyncedContent` for details.
    /// Returns the number of items hydrated.
    public var hydratePDFItemsFromSyncedContent: @Sendable () async throws -> Int
    /// Populates the local content table for text/markdown items that arrived
    /// via CloudKit sync. Mirrors `hydratePDFItemsFromSyncedContent`.
    public var hydrateTextItemsFromSyncedContent: @Sendable () async throws -> Int
    /// Re-populates `SavedTextContentSyncTable` from local content for any
    /// text items missing a sync row. Recovers from dropped tables and
    /// backfills items created before the sync table existed.
    public var backfillTextSyncTable: @Sendable () async throws -> Int

    // MARK: - Website archives

    /// Persists the original zip bytes for an imported website into the
    /// CloudKit-synced archive table. SQLiteData promotes the blob column to
    /// a CKAsset so the other device receives the full archive.
    public var saveWebsiteArchive: @Sendable (
        _ itemID: UUID,
        _ zipData: Data,
        _ sha256: String,
        _ originalFilename: String
    ) async throws -> Void
    /// Loads the zip bytes for an imported website. Returns nil when the row
    /// is absent or the blob has not yet been populated by sync.
    public var loadWebsiteArchive: @Sendable (UUID) async throws -> WebsiteArchiveBytes?
    /// Enqueues `hydrateWebsite` jobs for synced website rows whose local
    /// archive directory is missing. Returns the number of jobs enqueued.
    public var hydrateWebsiteItemsFromSyncedContent: @Sendable () async throws -> Int
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
            loadEditableTextSource: { _ in nil },
            saveReaderDocument: { _, _, _ in },
            saveEditedTextSource: { _, _ in nil },
            loadSourceHTML: { _ in nil },
            saveArticleCapture: { _, _ in },
            loadArticleCapture: { _ in nil },
            markArticleCaptureInstalled: { _, _, _ in },
            upsertMedia: { _, _ in },
            loadSummary: { _, _, _ in nil },
            saveSummary: { _, _, _, _ in },
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
            fetchTagIDsByItem: { _ in [:] },
            createTag: { name, _ in Tag(name: name) },
            renameTag: { _, _ in },
            deleteTag: { _ in },
            addTag: { _, _ in },
            removeTag: { _, _ in },
            reconcileOrphanedTagAssignments: { 0 },
            observeLibraryChanges: { AsyncStream { _ in } },
            loadSettings: { ImageDownloadSettings() },
            saveSettings: { _ in },
            loadReaderAppearanceSettings: { ReaderAppearanceSettings() },
            saveReaderAppearanceSettings: { _ in },
            enqueueIngestionJob: { _, _ in },
            claimNextIngestionJob: { _ in nil },
            claimNextIngestionJobOfKind: { _, _ in nil },
            completeIngestionJob: { _, _ in },
            failIngestionJob: { _, _, _ in },
            fetchFailedIngestionJobs: { [] },
            retryFailedIngestionJobs: {},
            dismissFailedIngestionJobs: { _ in },
            enqueueHydrationJobsForMissingContent: { 0 },
            hydratePDFItemsFromSyncedContent: { 0 },
            hydrateTextItemsFromSyncedContent: { 0 },
            backfillTextSyncTable: { 0 },
            saveWebsiteArchive: { _, _, _, _ in },
            loadWebsiteArchive: { _ in nil },
            hydrateWebsiteItemsFromSyncedContent: { 0 }
        )
    }()
}

// MARK: - Live (assembly only — each operation is in its own file)

extension StowerRepository {
    static func live(
        database: any DatabaseWriter,
        cloudSyncClient: CloudSyncClient
    ) -> Self {
        let scheduleSync: @Sendable () -> Void = {
            Task { await cloudSyncClient.scheduleSendChanges() }
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
        let loadEditableTextSource = _loadEditableTextSource(database: database)

        let baseUpdateFromIngestion = _updateItemFromIngestion(database: database, scheduleSync: scheduleSync)
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
        let baseCreateFromIngestion = _createItemFromIngestion(database: database, scheduleSync: scheduleSync)
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
        let softDelete = _softDeleteItem(database: database, scheduleSync: scheduleSync)
        let cachedDeleteItem: @Sendable (UUID) async throws -> Void = { id in
            try await softDelete(id)
        }

        // Hard-delete path also invalidates the reader cache.
        let rawPermanentDelete = _permanentlyDelete(database: database, scheduleSync: scheduleSync)
        let cachedPermanentDelete: @Sendable (UUID) async throws -> Void = { id in
            documentCache.invalidate(id)
            try await rawPermanentDelete(id)
        }

        return Self(
            fetchLibrary: _fetchLibraryFiltered(database: database),
            loadItem: _loadItem(database: database),
            createItemFromIngestion: cachedCreateFromIngestion,
            updateItemFromIngestion: cachedUpdateFromIngestion,
            hydrateItemContent: cachedHydrateItemContent,
            updateLocalContentStatus: _updateLocalContentStatus(database: database),
            loadReaderDocument: cachedLoadDocument,
            loadEditableTextSource: loadEditableTextSource,
            saveReaderDocument: cachedSaveDocument,
            saveEditedTextSource: cachedUpdateFromIngestion,
            loadSourceHTML: _loadSourceHTML(database: database),
            saveArticleCapture: _saveArticleCapture(database: database, scheduleSync: scheduleSync),
            loadArticleCapture: _loadArticleCapture(database: database),
            markArticleCaptureInstalled: _markArticleCaptureInstalled(database: database),
            upsertMedia: _upsertMedia(database: database),
            loadSummary: _loadSummary(database: database),
            saveSummary: _saveSummary(database: database),
            deleteItem: cachedDeleteItem,
            saveReadingProgress: _saveReadingProgress(database: database, scheduleSync: scheduleSync),
            setReadStatus: _setReadStatus(database: database, scheduleSync: scheduleSync),
            setStarred: _setStarred(database: database, scheduleSync: scheduleSync),
            restoreFromTrash: _restoreFromTrash(database: database, scheduleSync: scheduleSync),
            permanentlyDelete: cachedPermanentDelete,
            purgeOldTrash: _purgeOldTrash(database: database, scheduleSync: scheduleSync),
            fetchListCounts: _fetchListCounts(database: database),
            fetchTags: _fetchTags(database: database),
            fetchTagIDs: _fetchTagIDs(database: database),
            fetchTagIDsByItem: _fetchTagIDsByItem(database: database),
            createTag: _createTag(database: database, scheduleSync: scheduleSync),
            renameTag: _renameTag(database: database, scheduleSync: scheduleSync),
            deleteTag: _deleteTag(database: database, scheduleSync: scheduleSync),
            addTag: _addTag(database: database, scheduleSync: scheduleSync),
            removeTag: _removeTag(database: database, scheduleSync: scheduleSync),
            reconcileOrphanedTagAssignments: _reconcileOrphanedTagAssignments(
                database: database,
                scheduleSync: scheduleSync
            ),
            observeLibraryChanges: _observeLibraryChanges(database: database),
            loadSettings: _loadSettings(database: database),
            saveSettings: _saveSettings(database: database),
            loadReaderAppearanceSettings: _loadReaderAppearanceSettings(database: database),
            saveReaderAppearanceSettings: _saveReaderAppearanceSettings(database: database),
            enqueueIngestionJob: _enqueueIngestionJob(database: database),
            claimNextIngestionJob: _claimNextIngestionJob(database: database),
            claimNextIngestionJobOfKind: _claimNextIngestionJobOfKind(database: database),
            completeIngestionJob: _completeIngestionJob(database: database),
            failIngestionJob: _failIngestionJob(database: database),
            fetchFailedIngestionJobs: _fetchFailedIngestionJobs(database: database),
            retryFailedIngestionJobs: _retryFailedIngestionJobs(database: database),
            dismissFailedIngestionJobs: _dismissFailedIngestionJobs(database: database),
            enqueueHydrationJobsForMissingContent: _enqueueHydrationJobsForMissingContent(database: database),
            hydratePDFItemsFromSyncedContent: _hydratePDFItemsFromSyncedContent(database: database),
            hydrateTextItemsFromSyncedContent: _hydrateTextItemsFromSyncedContent(database: database),
            backfillTextSyncTable: _backfillTextSyncTable(database: database),
            saveWebsiteArchive: _saveWebsiteArchive(
                database: database,
                scheduleSync: scheduleSync
            ),
            loadWebsiteArchive: _loadWebsiteArchive(database: database),
            hydrateWebsiteItemsFromSyncedContent: _hydrateWebsiteItemsFromSyncedContent(
                database: database,
                archiveExists: websiteArchiveExists(itemID:)
            )
        )
    }
}
