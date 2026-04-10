import CryptoKit
import Dependencies
import Foundation
import SQLiteData

public struct StowerRepository: Sendable {
    public var fetchLibrary: @Sendable () async throws -> [SavedItem]
    public var loadItem: @Sendable (UUID) async throws -> SavedItem?
    public var createItemFromIngestion: @Sendable (IngestionResult) async throws -> SavedItem
    public var updateItemFromIngestion: @Sendable (UUID, IngestionResult) async throws -> SavedItem?
    public var hydrateItemContent: @Sendable (UUID, IngestionResult) async throws -> Void
    public var updateLocalContentStatus: @Sendable (UUID, String, String?) async throws -> Void
    public var loadReaderDocument: @Sendable (UUID) async throws -> ReaderDocument?
    public var saveReaderDocument: @Sendable (UUID, ReaderDocument, String) async throws -> Void
    public var loadSourceHTML: @Sendable (UUID) async throws -> String?
    public var upsertMedia: @Sendable ([MediaDescriptor], UUID) async throws -> Void
    public var deleteItem: @Sendable (UUID) async throws -> Void
    /// Persist the last-read block index for an item (scroll position restoration).
    public var saveReadingProgress: @Sendable (_ itemID: UUID, _ blockIndex: Int) async throws -> Void

    public var loadSettings: @Sendable () async throws -> ImageDownloadSettings
    public var saveSettings: @Sendable (ImageDownloadSettings) async throws -> Void
    public var loadReaderAppearanceSettings: @Sendable () async throws -> ReaderAppearanceSettings
    public var saveReaderAppearanceSettings: @Sendable (ReaderAppearanceSettings) async throws -> Void

    public var enqueueIngestionJob: @Sendable (IngestionJob.Kind, String) async throws -> Void
    public var fetchPendingIngestionJobs: @Sendable () async throws -> [IngestionJob]
    public var markIngestionJobProcessed: @Sendable (UUID) async throws -> Void

    public var enqueueHydrationJobsForMissingContent: @Sendable () async throws -> Int
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
        let fetchLibrary: @Sendable () async throws -> [SavedItem] = { [] }
        let loadItem: @Sendable (UUID) async throws -> SavedItem? = { _ in nil }
        let createItemFromIngestion: @Sendable (IngestionResult) async throws -> SavedItem = { _ in throw RepositoryError.notBootstrapped }
        let updateItemFromIngestion: @Sendable (UUID, IngestionResult) async throws -> SavedItem? = { _, _ in nil }
        let hydrateItemContent: @Sendable (UUID, IngestionResult) async throws -> Void = { _, _ in }
        let updateLocalContentStatus: @Sendable (UUID, String, String?) async throws -> Void = { _, _, _ in }
        let loadReaderDocument: @Sendable (UUID) async throws -> ReaderDocument? = { _ in nil }
        let saveReaderDocument: @Sendable (UUID, ReaderDocument, String) async throws -> Void = { _, _, _ in }
        let loadSourceHTML: @Sendable (UUID) async throws -> String? = { _ in nil }
        let upsertMedia: @Sendable ([MediaDescriptor], UUID) async throws -> Void = { _, _ in }
        let deleteItem: @Sendable (UUID) async throws -> Void = { _ in }
        let saveReadingProgress: @Sendable (UUID, Int) async throws -> Void = { _, _ in }
        let loadSettings: @Sendable () async throws -> ImageDownloadSettings = { ImageDownloadSettings() }
        let saveSettings: @Sendable (ImageDownloadSettings) async throws -> Void = { _ in }
        let loadReaderAppearanceSettings: @Sendable () async throws -> ReaderAppearanceSettings = { ReaderAppearanceSettings() }
        let saveReaderAppearanceSettings: @Sendable (ReaderAppearanceSettings) async throws -> Void = { _ in }
        let enqueueIngestionJob: @Sendable (IngestionJob.Kind, String) async throws -> Void = { _, _ in }
        let fetchPendingIngestionJobs: @Sendable () async throws -> [IngestionJob] = { [] }
        let markIngestionJobProcessed: @Sendable (UUID) async throws -> Void = { _ in }
        let enqueueHydrationJobsForMissingContent: @Sendable () async throws -> Int = { 0 }
        return StowerRepository(
            fetchLibrary: fetchLibrary,
            loadItem: loadItem,
            createItemFromIngestion: createItemFromIngestion,
            updateItemFromIngestion: updateItemFromIngestion,
            hydrateItemContent: hydrateItemContent,
            updateLocalContentStatus: updateLocalContentStatus,
            loadReaderDocument: loadReaderDocument,
            saveReaderDocument: saveReaderDocument,
            loadSourceHTML: loadSourceHTML,
            upsertMedia: upsertMedia,
            deleteItem: deleteItem,
            saveReadingProgress: saveReadingProgress,
            loadSettings: loadSettings,
            saveSettings: saveSettings,
            loadReaderAppearanceSettings: loadReaderAppearanceSettings,
            saveReaderAppearanceSettings: saveReaderAppearanceSettings,
            enqueueIngestionJob: enqueueIngestionJob,
            fetchPendingIngestionJobs: fetchPendingIngestionJobs,
            markIngestionJobProcessed: markIngestionJobProcessed,
            enqueueHydrationJobsForMissingContent: enqueueHydrationJobsForMissingContent
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
            if let cached = documentCache.get(id) { return cached }
            let document = try await baseLoadDocument(id)
            if let document { documentCache.set(id, document: document) }
            return document
        }

        let baseSaveDocument = _saveReaderDocument(database: database)
        let cachedSaveDocument: @Sendable (UUID, ReaderDocument, String) async throws -> Void = { id, document, html in
            try await baseSaveDocument(id, document, html)
            documentCache.set(id, document: document)
        }

        let baseUpdateFromIngestion = _updateItemFromIngestion(database: database, scheduleSync: scheduleSync)
        let cachedUpdateFromIngestion: @Sendable (UUID, IngestionResult) async throws -> SavedItem? = { id, result in
            documentCache.invalidate(id)
            return try await baseUpdateFromIngestion(id, result)
        }

        let baseDeleteItem = _deleteItem(database: database, scheduleSync: scheduleSync)
        let cachedDeleteItem: @Sendable (UUID) async throws -> Void = { id in
            documentCache.invalidate(id)
            try await baseDeleteItem(id)
        }

        return Self(
            fetchLibrary: _fetchLibrary(database: database),
            loadItem: _loadItem(database: database),
            createItemFromIngestion: _createItemFromIngestion(database: database, scheduleSync: scheduleSync),
            updateItemFromIngestion: cachedUpdateFromIngestion,
            hydrateItemContent: _hydrateItemContent(database: database),
            updateLocalContentStatus: _updateLocalContentStatus(database: database),
            loadReaderDocument: cachedLoadDocument,
            saveReaderDocument: cachedSaveDocument,
            loadSourceHTML: _loadSourceHTML(database: database),
            upsertMedia: _upsertMedia(database: database),
            deleteItem: cachedDeleteItem,
            saveReadingProgress: _saveReadingProgress(database: database, scheduleSync: scheduleSync),
            loadSettings: _loadSettings(database: database),
            saveSettings: _saveSettings(database: database),
            loadReaderAppearanceSettings: _loadReaderAppearanceSettings(database: database),
            saveReaderAppearanceSettings: _saveReaderAppearanceSettings(database: database),
            enqueueIngestionJob: _enqueueIngestionJob(database: database),
            fetchPendingIngestionJobs: _fetchPendingIngestionJobs(database: database),
            markIngestionJobProcessed: _markIngestionJobProcessed(database: database),
            enqueueHydrationJobsForMissingContent: _enqueueHydrationJobsForMissingContent(database: database)
        )
    }
}
