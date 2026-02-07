import Dependencies
import Foundation
import SQLiteData

public struct StowerRepository: Sendable {
    public var fetchLibrary: @Sendable () async throws -> [SavedItem]
    public var loadItem: @Sendable (UUID) async throws -> SavedItem?
    public var createItemFromIngestion: @Sendable (IngestionResult) async throws -> SavedItem
    public var updateItemFromIngestion: @Sendable (UUID, IngestionResult) async throws -> SavedItem?
    public var loadReaderDocument: @Sendable (UUID) async throws -> ReaderDocument?
    public var saveReaderDocument: @Sendable (UUID, ReaderDocument, String) async throws -> Void
    public var upsertMedia: @Sendable ([MediaDescriptor], UUID) async throws -> Void
    public var deleteItem: @Sendable (UUID) async throws -> Void

    public var loadSettings: @Sendable () async throws -> ImageDownloadSettings
    public var saveSettings: @Sendable (ImageDownloadSettings) async throws -> Void

    public var enqueueIngestionJob: @Sendable (IngestionJob.Kind, String) async throws -> Void
    public var fetchPendingIngestionJobs: @Sendable () async throws -> [IngestionJob]
    public var markIngestionJobProcessed: @Sendable (UUID) async throws -> Void
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

extension StowerRepository {
    static let failing = Self(
        fetchLibrary: { [] },
        loadItem: { _ in nil },
        createItemFromIngestion: { _ in
            throw RepositoryError.notBootstrapped
        },
        updateItemFromIngestion: { _, _ in nil },
        loadReaderDocument: { _ in nil },
        saveReaderDocument: { _, _, _ in },
        upsertMedia: { _, _ in },
        deleteItem: { _ in },
        loadSettings: { ImageDownloadSettings() },
        saveSettings: { _ in },
        enqueueIngestionJob: { _, _ in },
        fetchPendingIngestionJobs: { [] },
        markIngestionJobProcessed: { _ in }
    )

    static func live(database: any DatabaseWriter) -> Self {
        Self(
            fetchLibrary: {
                try database.read { db in
                    try SavedItemTable
                        .where { !$0.isArchived }
                        .order { $0.updatedAt.desc() }
                        .fetchAll(db)
                        .map(Self.toDomain)
                }
            },
            loadItem: { id in
                try database.read { db in
                    try SavedItemTable.find(id).fetchOne(db).map(Self.toDomain)
                }
            },
            createItemFromIngestion: { result in
                let now = Date.now
                let itemID = UUID()
                let draft = Self.makeItemDraft(id: itemID, result: result, now: now)

                try database.write { db in
                    try SavedItemTable.insert { draft }.execute(db)
                    try Self.persistDocumentAndMedia(db: db, itemID: itemID, result: result, now: now)
                }
                return Self.toDomain(from: draft)
            },
            updateItemFromIngestion: { id, result in
                let now = Date.now
                try database.write { db in
                    guard try SavedItemTable.find(id).fetchOne(db) != nil else {
                        return
                    }

                    try SavedItemTable.find(id).update {
                        $0.title = result.title
                        $0.sourceURL = result.sourceURL
                        $0.canonicalURL = result.canonicalURL
                        $0.renderFormat = result.renderFormat.rawValue
                        $0.documentVersion = result.document.version
                        $0.content = result.plainText
                        $0.excerpt = result.excerpt
                        $0.heroImageURL = result.heroImageURL
                        $0.author = result.author
                        $0.publishedAt = result.publishedAt
                        $0.siteName = result.siteName
                        $0.readingTimeMinutes = result.readingTimeMinutes
                        $0.hasRichMedia = result.hasRichMedia
                        $0.processingState = result.processingState.rawValue
                        $0.processingError = result.processingError
                        $0.updatedAt = now
                    }.execute(db)

                    try SavedDocumentTable
                        .where { $0.itemID == id }
                        .delete()
                        .execute(db)
                    try SavedMediaTable
                        .where { $0.itemID == id }
                        .delete()
                        .execute(db)
                    try SavedEmbedTable
                        .where { $0.itemID == id }
                        .delete()
                        .execute(db)

                    try Self.persistDocumentAndMedia(db: db, itemID: id, result: result, now: now)
                }

                return try database.read { db in
                    try SavedItemTable.find(id).fetchOne(db).map(Self.toDomain)
                }
            },
            loadReaderDocument: { id in
                try database.read { db in
                    let row = try SavedDocumentTable
                        .where { $0.itemID == id }
                        .order { $0.updatedAt.desc() }
                        .fetchOne(db)
                    guard let row else {
                        return nil
                    }
                    return try JSONDecoder().decode(ReaderDocument.self, from: Data(row.json.utf8))
                }
            },
            saveReaderDocument: { id, document, plainText in
                let now = Date.now
                let json = try String(decoding: JSONEncoder().encode(document), as: UTF8.self)
                let hash = Self.sha256(plainText)

                try database.write { db in
                    try SavedDocumentTable
                        .where { $0.itemID == id }
                        .delete()
                        .execute(db)
                    try SavedDocumentTable.insert {
                        SavedDocumentTable.Draft(
                            id: UUID(),
                            itemID: id,
                            json: json,
                            plainText: plainText,
                            sourceHTMLHash: hash,
                            createdAt: now,
                            updatedAt: now
                        )
                    }.execute(db)
                }
            },
            upsertMedia: { media, itemID in
                let now = Date.now
                try database.write { db in
                    try SavedMediaTable
                        .where { $0.itemID == itemID }
                        .delete()
                        .execute(db)

                    for descriptor in media {
                        try SavedMediaTable.insert {
                            SavedMediaTable.Draft(
                                id: UUID(),
                                itemID: itemID,
                                kind: descriptor.kind.rawValue,
                                sourceURL: descriptor.sourceURL,
                                localURL: descriptor.localURL,
                                mimeType: descriptor.mimeType,
                                width: descriptor.width,
                                height: descriptor.height,
                                durationSeconds: descriptor.durationSeconds,
                                posterURL: descriptor.posterURL,
                                caption: descriptor.caption,
                                status: "ready",
                                createdAt: now,
                                updatedAt: now
                            )
                        }.execute(db)
                    }
                }
            },
            deleteItem: { id in
                try database.write { db in
                    try SavedItemTable.find(id).delete().execute(db)
                }
            },
            loadSettings: {
                try database.read { db in
                    if let settings = try ImageDownloadSettingsTable.fetchOne(db) {
                        return ImageDownloadSettings(
                            globalAutoDownload: settings.globalAutoDownload,
                            askForNewSources: settings.askForNewSources
                        )
                    }
                    return ImageDownloadSettings()
                }
            },
            saveSettings: { settings in
                try database.write { db in
                    if let existing = try ImageDownloadSettingsTable.fetchOne(db) {
                        try ImageDownloadSettingsTable.find(existing.id).update {
                            $0.globalAutoDownload = settings.globalAutoDownload
                            $0.askForNewSources = settings.askForNewSources
                            $0.updatedAt = .now
                        }.execute(db)
                    } else {
                        try ImageDownloadSettingsTable.insert {
                            ImageDownloadSettingsTable.Draft(
                                id: UUID(),
                                globalAutoDownload: settings.globalAutoDownload,
                                askForNewSources: settings.askForNewSources,
                                updatedAt: .now
                            )
                        }.execute(db)
                    }
                }
            },
            enqueueIngestionJob: { kind, payload in
                try database.write { db in
                    try IngestionJobTable.insert {
                        IngestionJobTable.Draft(
                            id: UUID(),
                            kind: kind.rawValue,
                            payload: payload,
                            createdAt: .now,
                            processedAt: nil
                        )
                    }.execute(db)
                }
            },
            fetchPendingIngestionJobs: {
                try database.read { db in
                    try IngestionJobTable
                        .where { $0.processedAt.is(nil) }
                        .order { $0.createdAt }
                        .fetchAll(db)
                        .compactMap { (row: IngestionJobTable) -> IngestionJob? in
                            guard let kind = IngestionJob.Kind(rawValue: row.kind) else { return nil }
                            return IngestionJob(id: row.id, kind: kind, payload: row.payload, createdAt: row.createdAt)
                        }
                }
            },
            markIngestionJobProcessed: { id in
                try database.write { db in
                    try IngestionJobTable.find(id).update {
                        $0.processedAt = .now
                    }.execute(db)
                }
            }
        )
    }

    static func toDomain(_ row: SavedItemTable) -> SavedItem {
        SavedItem(
            id: row.id,
            title: row.title,
            sourceURL: row.sourceURL,
            canonicalURL: row.canonicalURL,
            renderFormat: RenderFormat(rawValue: row.renderFormat) ?? .plainText,
            documentVersion: row.documentVersion,
            content: row.content,
            excerpt: row.excerpt,
            heroImageURL: row.heroImageURL,
            author: row.author,
            publishedAt: row.publishedAt,
            siteName: row.siteName,
            readingTimeMinutes: row.readingTimeMinutes,
            hasRichMedia: row.hasRichMedia,
            processingState: ProcessingState(rawValue: row.processingState) ?? .queued,
            processingError: row.processingError,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    static func toDomain(from draft: SavedItemTable.Draft) -> SavedItem {
        SavedItem(
            id: draft.id ?? UUID(),
            title: draft.title,
            sourceURL: draft.sourceURL,
            canonicalURL: draft.canonicalURL,
            renderFormat: RenderFormat(rawValue: draft.renderFormat) ?? .plainText,
            documentVersion: draft.documentVersion,
            content: draft.content,
            excerpt: draft.excerpt,
            heroImageURL: draft.heroImageURL,
            author: draft.author,
            publishedAt: draft.publishedAt,
            siteName: draft.siteName,
            readingTimeMinutes: draft.readingTimeMinutes,
            hasRichMedia: draft.hasRichMedia,
            processingState: ProcessingState(rawValue: draft.processingState) ?? .queued,
            processingError: draft.processingError,
            createdAt: draft.createdAt,
            updatedAt: draft.updatedAt
        )
    }

    private static func makeItemDraft(id: UUID, result: IngestionResult, now: Date) -> SavedItemTable.Draft {
        SavedItemTable.Draft(
            id: id,
            title: result.title,
            sourceURL: result.sourceURL,
            canonicalURL: result.canonicalURL,
            renderFormat: result.renderFormat.rawValue,
            documentVersion: result.document.version,
            content: result.plainText,
            excerpt: result.excerpt,
            heroImageURL: result.heroImageURL,
            author: result.author,
            publishedAt: result.publishedAt,
            siteName: result.siteName,
            readingTimeMinutes: result.readingTimeMinutes,
            hasRichMedia: result.hasRichMedia,
            processingState: result.processingState.rawValue,
            processingError: result.processingError,
            createdAt: now,
            updatedAt: now,
            isArchived: false
        )
    }

    private static func persistDocumentAndMedia(
        db: Database,
        itemID: UUID,
        result: IngestionResult,
        now: Date
    ) throws {
        let json = try String(decoding: JSONEncoder().encode(result.document), as: UTF8.self)
        try SavedDocumentTable.insert {
            SavedDocumentTable.Draft(
                id: UUID(),
                itemID: itemID,
                json: json,
                plainText: result.plainText,
                sourceHTMLHash: sha256(result.plainText),
                createdAt: now,
                updatedAt: now
            )
        }.execute(db)

        for descriptor in result.media {
            try SavedMediaTable.insert {
                SavedMediaTable.Draft(
                    id: UUID(),
                    itemID: itemID,
                    kind: descriptor.kind.rawValue,
                    sourceURL: descriptor.sourceURL,
                    localURL: descriptor.localURL,
                    mimeType: descriptor.mimeType,
                    width: descriptor.width,
                    height: descriptor.height,
                    durationSeconds: descriptor.durationSeconds,
                    posterURL: descriptor.posterURL,
                    caption: descriptor.caption,
                    status: "ready",
                    createdAt: now,
                    updatedAt: now
                )
            }.execute(db)
        }

        for embed in result.embeds {
            try SavedEmbedTable.insert {
                SavedEmbedTable.Draft(
                    id: UUID(),
                    itemID: itemID,
                    provider: embed.provider,
                    embedURL: embed.embedURL,
                    htmlSnippet: embed.htmlSnippet,
                    status: "ready",
                    createdAt: now,
                    updatedAt: now
                )
            }.execute(db)
        }
    }

    private static func sha256(_ input: String) -> String {
        String(input.hashValue)
    }
}

public enum RepositoryError: Error {
    case notBootstrapped
}
