import Foundation
import Dependencies
import SQLiteData

// MARK: - Diagnostics Types

public struct SyncDiagnostics: Equatable, Sendable {
    public var syncedItemsCount: Int
    public var pendingChangesCount: Int
    public var metadataCount: Int
    public var sampleItems: [SyncItemSummary]

    public init(
        syncedItemsCount: Int,
        pendingChangesCount: Int,
        metadataCount: Int,
        sampleItems: [SyncItemSummary] = []
    ) {
        self.syncedItemsCount = syncedItemsCount
        self.pendingChangesCount = pendingChangesCount
        self.metadataCount = metadataCount
        self.sampleItems = sampleItems
    }
}

public struct SyncItemSummary: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var sourceURL: String?

    public init(id: UUID, title: String, sourceURL: String?) {
        self.id = id
        self.title = title
        self.sourceURL = sourceURL
    }
}

public struct SyncDiagnosticsClient: Sendable {
    public var load: @Sendable () async throws -> SyncDiagnostics

    public init(load: @escaping @Sendable () async throws -> SyncDiagnostics) {
        self.load = load
    }

    public static let noop = Self(load: {
        .init(syncedItemsCount: 0, pendingChangesCount: 0, metadataCount: 0, sampleItems: [])
    })
}

// MARK: - CloudSync Client Type

public struct CloudSyncClient: Sendable {
    public var start: @Sendable () async throws -> Void
    public var sendChanges: @Sendable () async throws -> Void
    public var scheduleSendChanges: @Sendable () async -> Void
    public var statusStream: @Sendable () -> AsyncStream<CloudSyncStatus>

    public init(
        start: @escaping @Sendable () async throws -> Void,
        sendChanges: @escaping @Sendable () async throws -> Void,
        scheduleSendChanges: @escaping @Sendable () async -> Void,
        statusStream: @escaping @Sendable () -> AsyncStream<CloudSyncStatus>
    ) {
        self.start = start
        self.sendChanges = sendChanges
        self.scheduleSendChanges = scheduleSendChanges
        self.statusStream = statusStream
    }

    public static let noop = Self(
        start: {},
        sendChanges: {},
        scheduleSendChanges: {},
        statusStream: { AsyncStream { _ in } }
    )
}

// MARK: - Database Setup & Migrations

public enum StowerDatabase {
    public static let appGroupID = "group.com.ryanleewilliams.stower"
    public static let cloudKitContainerID = "iCloud.com.ryanleewilliams.stower"

    public static func makeDatabase() throws -> any DatabaseWriter {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            do { try db.attachMetadatabase() } catch {
                #if DEBUG
                print("⚠️ SQLiteData metadatabase unavailable: \(error)")
                #endif
            }
        }
        let db = try SQLiteData.defaultDatabase(configuration: configuration)
        try migrate(database: db)
        return db
    }

    private static func migrate(database: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.eraseDatabaseOnSchemaChange = false
        migrator.registerMigration("create-stower-v2-reader") { db in try migration_v1(db) }
        migrator.registerMigration("cloudkit-split-sync-v1") { db in try migration_v2(db) }
        migrator.registerMigration("add-source-html-to-content") { db in try migration_v3(db) }
        migrator.registerMigration("add-last-read-block-index") { db in try migration_v4(db) }
        try migrator.migrate(database)
    }

    private static func migration_v1(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "savedItemTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "title" TEXT NOT NULL, "sourceURL" TEXT,
              "canonicalURL" TEXT, "renderFormat" TEXT NOT NULL DEFAULT 'structuredV1',
              "documentVersion" INTEGER NOT NULL DEFAULT 1, "content" TEXT NOT NULL,
              "excerpt" TEXT, "heroImageURL" TEXT, "author" TEXT, "publishedAt" TEXT,
              "siteName" TEXT, "readingTimeMinutes" INTEGER,
              "hasRichMedia" INTEGER NOT NULL DEFAULT 0,
              "processingState" TEXT NOT NULL DEFAULT 'queued', "processingError" TEXT,
              "createdAt" TEXT NOT NULL, "updatedAt" TEXT NOT NULL,
              "isArchived" INTEGER NOT NULL DEFAULT 0
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "savedDocumentTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "itemID" TEXT NOT NULL, "json" TEXT NOT NULL,
              "plainText" TEXT NOT NULL, "sourceHTMLHash" TEXT NOT NULL,
              "createdAt" TEXT NOT NULL, "updatedAt" TEXT NOT NULL,
              FOREIGN KEY("itemID") REFERENCES "savedItemTables"("id") ON DELETE CASCADE
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "savedMediaTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "itemID" TEXT NOT NULL, "kind" TEXT NOT NULL,
              "sourceURL" TEXT NOT NULL, "localURL" TEXT, "mimeType" TEXT, "width" INTEGER,
              "height" INTEGER, "durationSeconds" REAL, "posterURL" TEXT, "caption" TEXT,
              "status" TEXT NOT NULL DEFAULT 'ready', "createdAt" TEXT NOT NULL, "updatedAt" TEXT NOT NULL,
              FOREIGN KEY("itemID") REFERENCES "savedItemTables"("id") ON DELETE CASCADE
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "savedEmbedTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "itemID" TEXT NOT NULL, "provider" TEXT NOT NULL,
              "embedURL" TEXT NOT NULL, "htmlSnippet" TEXT, "status" TEXT NOT NULL DEFAULT 'ready',
              "createdAt" TEXT NOT NULL, "updatedAt" TEXT NOT NULL,
              FOREIGN KEY("itemID") REFERENCES "savedItemTables"("id") ON DELETE CASCADE
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "savedImageRefTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "itemID" TEXT NOT NULL, "sourceURL" TEXT,
              "width" INTEGER NOT NULL DEFAULT 0, "height" INTEGER NOT NULL DEFAULT 0,
              "sha256" TEXT NOT NULL DEFAULT '', "status" TEXT NOT NULL DEFAULT 'pending',
              "createdAt" TEXT NOT NULL,
              FOREIGN KEY("itemID") REFERENCES "savedItemTables"("id") ON DELETE CASCADE
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "savedImageAssetTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "itemID" TEXT NOT NULL, "imageData" BLOB NOT NULL,
              "width" INTEGER NOT NULL DEFAULT 0, "height" INTEGER NOT NULL DEFAULT 0,
              "format" TEXT NOT NULL DEFAULT 'jpg', "createdAt" TEXT NOT NULL,
              FOREIGN KEY("itemID") REFERENCES "savedItemTables"("id") ON DELETE CASCADE
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "imageDownloadSettingsTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "globalAutoDownload" INTEGER NOT NULL DEFAULT 0,
              "askForNewSources" INTEGER NOT NULL DEFAULT 1, "updatedAt" TEXT NOT NULL
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "readerAppearanceSettingsTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "fontSize" REAL NOT NULL DEFAULT 19,
              "fontStyle" TEXT NOT NULL DEFAULT 'newYork', "lineSpacing" REAL NOT NULL DEFAULT 8,
              "justification" TEXT NOT NULL DEFAULT 'leading', "theme" TEXT NOT NULL DEFAULT 'white',
              "lineWidth" REAL NOT NULL DEFAULT 820, "updatedAt" TEXT NOT NULL
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "ingestionJobTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "kind" TEXT NOT NULL, "payload" TEXT NOT NULL,
              "createdAt" TEXT NOT NULL, "processedAt" TEXT
            ) STRICT
            """)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedItemTables_updatedAt ON "savedItemTables"("updatedAt" DESC)"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedItemTables_processingState ON "savedItemTables"("processingState")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedDocumentTables_itemID ON "savedDocumentTables"("itemID")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedMediaTables_itemID ON "savedMediaTables"("itemID")"#)
        try db.execute(sql: #"CREATE UNIQUE INDEX IF NOT EXISTS idx_savedMediaTables_item_source ON "savedMediaTables"("itemID", "sourceURL")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedEmbedTables_itemID ON "savedEmbedTables"("itemID")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_ingestionJobTables_processedAt ON "ingestionJobTables"("processedAt")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedImageRefTables_itemID ON "savedImageRefTables"("itemID")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedImageAssetTables_itemID ON "savedImageAssetTables"("itemID")"#)
    }

    private static func migration_v2(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "savedItemSyncTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "title" TEXT NOT NULL, "sourceURL" TEXT,
              "canonicalURL" TEXT, "excerpt" TEXT, "heroImageURL" TEXT, "author" TEXT,
              "publishedAt" TEXT, "siteName" TEXT, "readingTimeMinutes" INTEGER,
              "hasRichMedia" INTEGER NOT NULL DEFAULT 0, "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL, "isArchived" INTEGER NOT NULL DEFAULT 0
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "savedItemContentLocalTables" (
              "itemID" TEXT PRIMARY KEY NOT NULL, "renderFormat" TEXT NOT NULL DEFAULT 'structuredV1',
              "documentVersion" INTEGER NOT NULL DEFAULT 1, "plainText" TEXT NOT NULL DEFAULT '',
              "documentJSON" TEXT NOT NULL DEFAULT '', "sourceHTMLHash" TEXT NOT NULL DEFAULT '',
              "localStatus" TEXT NOT NULL DEFAULT 'notDownloaded', "localError" TEXT,
              "createdAt" TEXT NOT NULL, "updatedAt" TEXT NOT NULL,
              FOREIGN KEY("itemID") REFERENCES "savedItemSyncTables"("id") ON DELETE CASCADE
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "savedMediaLocalTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "itemID" TEXT NOT NULL, "kind" TEXT NOT NULL,
              "sourceURL" TEXT NOT NULL, "localURL" TEXT, "mimeType" TEXT, "width" INTEGER,
              "height" INTEGER, "durationSeconds" REAL, "posterURL" TEXT, "caption" TEXT,
              "status" TEXT NOT NULL DEFAULT 'ready', "createdAt" TEXT NOT NULL, "updatedAt" TEXT NOT NULL,
              FOREIGN KEY("itemID") REFERENCES "savedItemSyncTables"("id") ON DELETE CASCADE
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "savedEmbedLocalTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "itemID" TEXT NOT NULL, "provider" TEXT NOT NULL,
              "embedURL" TEXT NOT NULL, "htmlSnippet" TEXT, "status" TEXT NOT NULL DEFAULT 'ready',
              "createdAt" TEXT NOT NULL, "updatedAt" TEXT NOT NULL,
              FOREIGN KEY("itemID") REFERENCES "savedItemSyncTables"("id") ON DELETE CASCADE
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "savedImageRefLocalTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "itemID" TEXT NOT NULL, "sourceURL" TEXT,
              "width" INTEGER NOT NULL DEFAULT 0, "height" INTEGER NOT NULL DEFAULT 0,
              "sha256" TEXT NOT NULL DEFAULT '', "status" TEXT NOT NULL DEFAULT 'pending',
              "createdAt" TEXT NOT NULL,
              FOREIGN KEY("itemID") REFERENCES "savedItemSyncTables"("id") ON DELETE CASCADE
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "savedImageAssetLocalTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "itemID" TEXT NOT NULL, "imageData" BLOB NOT NULL,
              "width" INTEGER NOT NULL DEFAULT 0, "height" INTEGER NOT NULL DEFAULT 0,
              "format" TEXT NOT NULL DEFAULT 'jpg', "createdAt" TEXT NOT NULL,
              FOREIGN KEY("itemID") REFERENCES "savedItemSyncTables"("id") ON DELETE CASCADE
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "imageDownloadSettingsLocalTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "globalAutoDownload" INTEGER NOT NULL DEFAULT 0,
              "askForNewSources" INTEGER NOT NULL DEFAULT 1, "updatedAt" TEXT NOT NULL
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "readerAppearanceSettingsLocalTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "fontSize" REAL NOT NULL DEFAULT 19,
              "fontStyle" TEXT NOT NULL DEFAULT 'newYork', "lineSpacing" REAL NOT NULL DEFAULT 8,
              "justification" TEXT NOT NULL DEFAULT 'leading', "theme" TEXT NOT NULL DEFAULT 'white',
              "lineWidth" REAL NOT NULL DEFAULT 820, "updatedAt" TEXT NOT NULL
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "ingestionJobLocalTables" (
              "id" TEXT PRIMARY KEY NOT NULL, "kind" TEXT NOT NULL, "payload" TEXT NOT NULL,
              "createdAt" TEXT NOT NULL, "processedAt" TEXT
            ) STRICT
            """)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedItemSyncTables_updatedAt ON "savedItemSyncTables"("updatedAt" DESC)"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedItemSyncTables_isArchived ON "savedItemSyncTables"("isArchived")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedItemContentLocalTables_itemID ON "savedItemContentLocalTables"("itemID")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedMediaLocalTables_itemID ON "savedMediaLocalTables"("itemID")"#)
        try db.execute(sql: #"CREATE UNIQUE INDEX IF NOT EXISTS idx_savedMediaLocalTables_item_source ON "savedMediaLocalTables"("itemID", "sourceURL")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedEmbedLocalTables_itemID ON "savedEmbedLocalTables"("itemID")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_ingestionJobLocalTables_processedAt ON "ingestionJobLocalTables"("processedAt")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedImageRefLocalTables_itemID ON "savedImageRefLocalTables"("itemID")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedImageAssetLocalTables_itemID ON "savedImageAssetLocalTables"("itemID")"#)
        do {
            try db.execute(sql: """
                INSERT OR IGNORE INTO "savedItemSyncTables" ("id","title","sourceURL","canonicalURL","excerpt","heroImageURL","author","publishedAt","siteName","readingTimeMinutes","hasRichMedia","createdAt","updatedAt","isArchived")
                SELECT "id","title","sourceURL","canonicalURL","excerpt","heroImageURL","author","publishedAt","siteName","readingTimeMinutes","hasRichMedia","createdAt","updatedAt","isArchived" FROM "savedItemTables"
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO "savedItemContentLocalTables" ("itemID","renderFormat","documentVersion","plainText","documentJSON","sourceHTMLHash","localStatus","localError","createdAt","updatedAt")
                SELECT i."id", i."renderFormat", i."documentVersion", coalesce(d."plainText",''), coalesce(d."json",''), coalesce(d."sourceHTMLHash",''),
                  CASE WHEN coalesce(d."json",'') = '' THEN 'notDownloaded' ELSE 'available' END,
                  i."processingError", i."createdAt", i."updatedAt"
                FROM "savedItemTables" i LEFT JOIN "savedDocumentTables" d ON d."itemID" = i."id"
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO "savedMediaLocalTables" ("id","itemID","kind","sourceURL","localURL","mimeType","width","height","durationSeconds","posterURL","caption","status","createdAt","updatedAt")
                SELECT "id","itemID","kind","sourceURL","localURL","mimeType","width","height","durationSeconds","posterURL","caption","status","createdAt","updatedAt" FROM "savedMediaTables"
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO "savedEmbedLocalTables" ("id","itemID","provider","embedURL","htmlSnippet","status","createdAt","updatedAt")
                SELECT "id","itemID","provider","embedURL","htmlSnippet","status","createdAt","updatedAt" FROM "savedEmbedTables"
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO "savedImageRefLocalTables" ("id","itemID","sourceURL","width","height","sha256","status","createdAt")
                SELECT "id","itemID","sourceURL","width","height","sha256","status","createdAt" FROM "savedImageRefTables"
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO "savedImageAssetLocalTables" ("id","itemID","imageData","width","height","format","createdAt")
                SELECT "id","itemID","imageData","width","height","format","createdAt" FROM "savedImageAssetTables"
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO "imageDownloadSettingsLocalTables" ("id","globalAutoDownload","askForNewSources","updatedAt")
                SELECT "id","globalAutoDownload","askForNewSources","updatedAt" FROM "imageDownloadSettingsTables"
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO "readerAppearanceSettingsLocalTables" ("id","fontSize","fontStyle","lineSpacing","justification","theme","lineWidth","updatedAt")
                SELECT "id","fontSize","fontStyle","lineSpacing","justification","theme","lineWidth","updatedAt" FROM "readerAppearanceSettingsTables"
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO "ingestionJobLocalTables" ("id","kind","payload","createdAt","processedAt")
                SELECT "id","kind","payload","createdAt","processedAt" FROM "ingestionJobTables"
                """)
            try db.execute(sql: #"DROP TABLE IF EXISTS "savedDocumentTables""#)
            try db.execute(sql: #"DROP TABLE IF EXISTS "savedMediaTables""#)
            try db.execute(sql: #"DROP TABLE IF EXISTS "savedEmbedTables""#)
            try db.execute(sql: #"DROP TABLE IF EXISTS "savedImageRefTables""#)
            try db.execute(sql: #"DROP TABLE IF EXISTS "savedImageAssetTables""#)
            try db.execute(sql: #"DROP TABLE IF EXISTS "imageDownloadSettingsTables""#)
            try db.execute(sql: #"DROP TABLE IF EXISTS "readerAppearanceSettingsTables""#)
            try db.execute(sql: #"DROP TABLE IF EXISTS "ingestionJobTables""#)
            try db.execute(sql: #"DROP TABLE IF EXISTS "savedItemTables""#)
        } catch { /* old schema absent — ignore */ }
    }

    private static func migration_v3(_ db: Database) throws {
        try db.execute(sql: #"ALTER TABLE "savedItemContentLocalTables" ADD COLUMN "sourceHTML" TEXT NOT NULL DEFAULT ''"#)
    }

    private static func migration_v4(_ db: Database) throws {
        // Reading-position persistence column on the sync table.
        // Nullable so unread articles are distinguishable from "at top".
        try db.execute(sql: #"ALTER TABLE "savedItemSyncTables" ADD COLUMN "lastReadBlockIndex" INTEGER"#)
    }
}

// MARK: - Dependency Keys

private enum CloudSyncClientKey: DependencyKey {
    static let liveValue: CloudSyncClient = .noop
    static let testValue: CloudSyncClient = .noop
}

private enum SyncDiagnosticsClientKey: DependencyKey {
    static let liveValue: SyncDiagnosticsClient = .noop
    static let testValue: SyncDiagnosticsClient = .noop
}

extension DependencyValues {
    public var cloudSyncClient: CloudSyncClient {
        get { self[CloudSyncClientKey.self] }
        set { self[CloudSyncClientKey.self] = newValue }
    }

    public var syncDiagnosticsClient: SyncDiagnosticsClient {
        get { self[SyncDiagnosticsClientKey.self] }
        set { self[SyncDiagnosticsClientKey.self] = newValue }
    }

    public mutating func bootstrapStowerDatabase(
        enableSync: Bool = true,
        syncEngineDelegate: (any SyncEngineDelegate)? = nil
    ) throws {
        let database = try StowerDatabase.makeDatabase()
        defaultDatabase = database

        if enableSync {
            let (client, engine) = StowerDatabase.makeCloudSyncClient(
                database: database,
                syncEngineDelegate: syncEngineDelegate
            )
            cloudSyncClient = client
            if let engine { defaultSyncEngine = engine }
        } else {
            cloudSyncClient = .noop
        }

        syncDiagnosticsClient = SyncDiagnosticsClient(
            load: StowerDatabase.makeDiagnosticsLoad(database: database)
        )
        stowerRepository = .live(database: database, cloudSyncClient: cloudSyncClient)
    }
}
