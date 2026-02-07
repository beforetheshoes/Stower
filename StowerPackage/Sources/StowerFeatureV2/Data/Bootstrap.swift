import Foundation
import Dependencies
import SQLiteData

public enum StowerDatabase {
    public static let appGroupID = "group.com.ryanleewilliams.stower"

    public static func makeDatabase() throws -> any DatabaseWriter {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            do {
                try db.attachMetadatabase()
            } catch {
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
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("create-stower-v2-reader") { db in
            try #sql(
                """
                CREATE TABLE IF NOT EXISTS "savedItemTables" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "title" TEXT NOT NULL,
                  "sourceURL" TEXT,
                  "canonicalURL" TEXT,
                  "renderFormat" TEXT NOT NULL DEFAULT 'structuredV1',
                  "documentVersion" INTEGER NOT NULL DEFAULT 1,
                  "content" TEXT NOT NULL,
                  "excerpt" TEXT,
                  "heroImageURL" TEXT,
                  "author" TEXT,
                  "publishedAt" TEXT,
                  "siteName" TEXT,
                  "readingTimeMinutes" INTEGER,
                  "hasRichMedia" INTEGER NOT NULL DEFAULT 0,
                  "processingState" TEXT NOT NULL DEFAULT 'queued',
                  "processingError" TEXT,
                  "createdAt" TEXT NOT NULL,
                  "updatedAt" TEXT NOT NULL,
                  "isArchived" INTEGER NOT NULL DEFAULT 0
                ) STRICT
                """
            ).execute(db)

            try #sql(
                """
                CREATE TABLE IF NOT EXISTS "savedDocumentTables" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "itemID" TEXT NOT NULL,
                  "json" TEXT NOT NULL,
                  "plainText" TEXT NOT NULL,
                  "sourceHTMLHash" TEXT NOT NULL,
                  "createdAt" TEXT NOT NULL,
                  "updatedAt" TEXT NOT NULL,
                  FOREIGN KEY("itemID") REFERENCES "savedItemTables"("id") ON DELETE CASCADE
                ) STRICT
                """
            ).execute(db)

            try #sql(
                """
                CREATE TABLE IF NOT EXISTS "savedMediaTables" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "itemID" TEXT NOT NULL,
                  "kind" TEXT NOT NULL,
                  "sourceURL" TEXT NOT NULL,
                  "localURL" TEXT,
                  "mimeType" TEXT,
                  "width" INTEGER,
                  "height" INTEGER,
                  "durationSeconds" REAL,
                  "posterURL" TEXT,
                  "caption" TEXT,
                  "status" TEXT NOT NULL DEFAULT 'ready',
                  "createdAt" TEXT NOT NULL,
                  "updatedAt" TEXT NOT NULL,
                  FOREIGN KEY("itemID") REFERENCES "savedItemTables"("id") ON DELETE CASCADE
                ) STRICT
                """
            ).execute(db)

            try #sql(
                """
                CREATE TABLE IF NOT EXISTS "savedEmbedTables" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "itemID" TEXT NOT NULL,
                  "provider" TEXT NOT NULL,
                  "embedURL" TEXT NOT NULL,
                  "htmlSnippet" TEXT,
                  "status" TEXT NOT NULL DEFAULT 'ready',
                  "createdAt" TEXT NOT NULL,
                  "updatedAt" TEXT NOT NULL,
                  FOREIGN KEY("itemID") REFERENCES "savedItemTables"("id") ON DELETE CASCADE
                ) STRICT
                """
            ).execute(db)

            try #sql(
                """
                CREATE TABLE IF NOT EXISTS "savedImageRefTables" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "itemID" TEXT NOT NULL,
                  "sourceURL" TEXT,
                  "width" INTEGER NOT NULL DEFAULT 0,
                  "height" INTEGER NOT NULL DEFAULT 0,
                  "sha256" TEXT NOT NULL DEFAULT '',
                  "status" TEXT NOT NULL DEFAULT 'pending',
                  "createdAt" TEXT NOT NULL,
                  FOREIGN KEY("itemID") REFERENCES "savedItemTables"("id") ON DELETE CASCADE
                ) STRICT
                """
            ).execute(db)

            try #sql(
                """
                CREATE TABLE IF NOT EXISTS "savedImageAssetTables" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "itemID" TEXT NOT NULL,
                  "imageData" BLOB NOT NULL,
                  "width" INTEGER NOT NULL DEFAULT 0,
                  "height" INTEGER NOT NULL DEFAULT 0,
                  "format" TEXT NOT NULL DEFAULT 'jpg',
                  "createdAt" TEXT NOT NULL,
                  FOREIGN KEY("itemID") REFERENCES "savedItemTables"("id") ON DELETE CASCADE
                ) STRICT
                """
            ).execute(db)

            try #sql(
                """
                CREATE TABLE IF NOT EXISTS "imageDownloadSettingsTables" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "globalAutoDownload" INTEGER NOT NULL DEFAULT 0,
                  "askForNewSources" INTEGER NOT NULL DEFAULT 1,
                  "updatedAt" TEXT NOT NULL
                ) STRICT
                """
            ).execute(db)

            try #sql(
                """
                CREATE TABLE IF NOT EXISTS "ingestionJobTables" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "kind" TEXT NOT NULL,
                  "payload" TEXT NOT NULL,
                  "createdAt" TEXT NOT NULL,
                  "processedAt" TEXT
                ) STRICT
                """
            ).execute(db)

            try #sql("CREATE INDEX IF NOT EXISTS idx_savedItemTables_updatedAt ON \"savedItemTables\"(\"updatedAt\" DESC)").execute(db)
            try #sql("CREATE INDEX IF NOT EXISTS idx_savedItemTables_processingState ON \"savedItemTables\"(\"processingState\")").execute(db)
            try #sql("CREATE INDEX IF NOT EXISTS idx_savedDocumentTables_itemID ON \"savedDocumentTables\"(\"itemID\")").execute(db)
            try #sql("CREATE INDEX IF NOT EXISTS idx_savedMediaTables_itemID ON \"savedMediaTables\"(\"itemID\")").execute(db)
            try #sql("CREATE UNIQUE INDEX IF NOT EXISTS idx_savedMediaTables_item_source ON \"savedMediaTables\"(\"itemID\", \"sourceURL\")").execute(db)
            try #sql("CREATE INDEX IF NOT EXISTS idx_savedEmbedTables_itemID ON \"savedEmbedTables\"(\"itemID\")").execute(db)
            try #sql("CREATE INDEX IF NOT EXISTS idx_ingestionJobTables_processedAt ON \"ingestionJobTables\"(\"processedAt\")").execute(db)
            try #sql("CREATE INDEX IF NOT EXISTS idx_savedImageRefTables_itemID ON \"savedImageRefTables\"(\"itemID\")").execute(db)
            try #sql("CREATE INDEX IF NOT EXISTS idx_savedImageAssetTables_itemID ON \"savedImageAssetTables\"(\"itemID\")").execute(db)
        }

        try migrator.migrate(database)
    }
}

public struct CloudSyncClient: Sendable {
    public var start: @Sendable () async throws -> Void
    public var sendChanges: @Sendable () async throws -> Void

    public init(
        start: @escaping @Sendable () async throws -> Void,
        sendChanges: @escaping @Sendable () async throws -> Void
    ) {
        self.start = start
        self.sendChanges = sendChanges
    }

    public static let noop = Self(start: {}, sendChanges: {})
}

private enum CloudSyncClientKey: DependencyKey {
    static let liveValue: CloudSyncClient = .noop
    static let testValue: CloudSyncClient = .noop
}

extension DependencyValues {
    public var cloudSyncClient: CloudSyncClient {
        get { self[CloudSyncClientKey.self] }
        set { self[CloudSyncClientKey.self] = newValue }
    }

    public mutating func bootstrapStowerDatabase(
        syncEngineDelegate: (any SyncEngineDelegate)? = nil
    ) throws {
        let database = try StowerDatabase.makeDatabase()
        defaultDatabase = database

        do {
            let syncEngine = try SyncEngine(
                for: database,
                tables: SavedItemTable.self,
                SavedDocumentTable.self,
                SavedMediaTable.self,
                SavedEmbedTable.self,
                SavedImageRefTable.self,
                SavedImageAssetTable.self,
                ImageDownloadSettingsTable.self,
                IngestionJobTable.self,
                delegate: syncEngineDelegate
            )
            defaultSyncEngine = syncEngine
            cloudSyncClient = CloudSyncClient(
                start: { try await syncEngine.start() },
                sendChanges: { try await syncEngine.sendChanges() }
            )
        } catch {
            cloudSyncClient = .noop
        }

        stowerRepository = .live(database: database)
    }
}
