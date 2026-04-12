import Dependencies
import Foundation
import SQLiteData

// MARK: - Diagnostics Types

public struct SyncDiagnostics: Equatable, Sendable {
    public var syncedItemsCount: Int
    public var syncedTagsCount: Int
    public var syncedItemTagsCount: Int
    public var pendingChangesCount: Int
    public var metadataCount: Int
    public let sampleItems: [SyncItemSummary]

    public init(
        syncedItemsCount: Int,
        pendingChangesCount: Int,
        metadataCount: Int,
        syncedTagsCount: Int = 0,
        syncedItemTagsCount: Int = 0,
        sampleItems: [SyncItemSummary] = []
    ) {
        self.syncedItemsCount = syncedItemsCount
        self.syncedTagsCount = syncedTagsCount
        self.syncedItemTagsCount = syncedItemTagsCount
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

    public static let noop = Self {
        .init(syncedItemsCount: 0, pendingChangesCount: 0, metadataCount: 0, sampleItems: [])
    }
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
    // The App Group ID is derived at runtime from the host app's bundle
    // identifier. Debug builds use `com.ryanleewilliams.stower.dev`
    // (set via `Config/Debug.xcconfig`), which maps to the `.dev` App
    // Group so Debug and Release use physically separate `stower.sqlite`
    // files and can install side-by-side. A compile-time `#if` flag
    // can't be used here because Xcode doesn't propagate target-level
    // `SWIFT_ACTIVE_COMPILATION_CONDITIONS` to Swift package dependencies.
    //
    // The CloudKit container ID is the same in both configurations —
    // Apple's code-signing automatically routes debug binaries to the
    // Dev CloudKit environment and distribution binaries to Prod.
    public static var appGroupID: String {
        let isDevBuild = Bundle.main.bundleIdentifier?.contains(".dev") == true
        return isDevBuild ? "group.com.Stower.dev" : "group.com.Stower"
    }
    public static let cloudKitContainerID = "iCloud.Stower"

    public enum DatabaseError: Error, LocalizedError {
        case appGroupContainerUnavailable(groupID: String)

        public var errorDescription: String? {
            switch self {
            case .appGroupContainerUnavailable(let groupID):
                return "App Group container '\(groupID)' is not available. Confirm both the main app and the share extension declare it in their entitlements and that the App Group is provisioned in the developer portal."
            }
        }
    }

    public static func makeDatabase() throws -> any DatabaseWriter {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            do {
                try db.attachMetadatabase(containerIdentifier: cloudKitContainerID)
            } catch {
                #if DEBUG
                // swiftlint:disable:next no_print_statements
                print("⚠️ SQLiteData metadatabase unavailable: \(error)")
                #endif
            }
        }

        #if DEBUG
        // swiftlint:disable:next no_print_statements
        print("🔧 Bootstrap: appGroupID = \(appGroupID)")
        // swiftlint:disable:next no_print_statements
        print("🔧 Bootstrap: cloudKitContainerID = \(cloudKitContainerID)")
        #endif

        // In .live, the database lives in the App Group container so the share
        // extension and the main app can both read and write the same file.
        // In .preview / .test, SQLiteData ignores `path` and uses a tempfile.
        let resolvedPath: String?
        @Dependency(\.context)
        var context
        if context == .live {
            let url = try resolveAppGroupDatabaseURL()
            try migrateLegacySandboxDatabaseIfNeeded(to: url)
            resolvedPath = url.path
        } else {
            resolvedPath = nil
        }

        let db = try SQLiteData.defaultDatabase(path: resolvedPath, configuration: configuration)
        try migrate(database: db)
        return db
    }

    private static func resolveAppGroupDatabaseURL() throws -> URL {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else {
            throw DatabaseError.appGroupContainerUnavailable(groupID: appGroupID)
        }
        let directory = containerURL.appendingPathComponent("Database", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("stower.sqlite")
    }

    /// One-time migration: if a sandbox-located database from before the App
    /// Group move exists, copy it (and its WAL/SHM sidecars) into the App Group
    /// container so existing data isn't lost. The legacy file is left in place
    /// as a recovery copy and can be deleted by the user later.
    private static func migrateLegacySandboxDatabaseIfNeeded(to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return
        }
        guard let legacyURL = try legacyDefaultDatabaseURL() else { return }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }

        try FileManager.default.copyItem(at: legacyURL, to: destination)

        let legacyWAL = legacyURL.appendingPathExtension("wal")
        if FileManager.default.fileExists(atPath: legacyWAL.path) {
            try? FileManager.default.copyItem(
                at: legacyWAL,
                to: destination.appendingPathExtension("wal")
            )
        }
        let legacySHM = legacyURL.appendingPathExtension("shm")
        if FileManager.default.fileExists(atPath: legacySHM.path) {
            try? FileManager.default.copyItem(
                at: legacySHM,
                to: destination.appendingPathExtension("shm")
            )
        }

        #if DEBUG
        // swiftlint:disable:next no_print_statements
        print("ℹ️ Migrated legacy Stower database from \(legacyURL.path) to \(destination.path)")
        #endif
    }

    /// Mirrors `SQLiteData.defaultDatabase`'s `.live` default path so we can
    /// detect a pre-existing sandbox database during the App Group migration.
    private static func legacyDefaultDatabaseURL() throws -> URL? {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return applicationSupport.appendingPathComponent("SQLiteData.db")
    }

    private static func migrate(database: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.eraseDatabaseOnSchemaChange = false
        migrator.registerMigration("create-stower-v2-reader") { db in
            try migration_v1(db)
        }
        migrator.registerMigration("cloudkit-split-sync-v1") { db in
            try migration_v2(db)
        }
        migrator.registerMigration("add-source-html-to-content") { db in
            try migration_v3(db)
        }
        migrator.registerMigration("add-last-read-block-index") { db in
            try migration_v4(db)
        }
        migrator.registerMigration("add-isread-isstarred-softdelete-and-tags") { db in
            try migration_v5(db)
        }
        migrator.registerMigration("drop-unique-indexes-from-sync-tables") { db in
            try migration_v6(db)
        }
        migrator.registerMigration("add-ai-summary-columns") { db in
            try migration_v7(db)
        }
        migrator.registerMigration("add-pdf-support") { db in
            try migration_v8(db)
        }
        migrator.registerMigration("flexoki-background-accents") { db in
            try migration_v9(db)
        }
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

    private static func migration_v5(_ db: Database) throws {
        // New columns on the sync table for read/starred state and soft delete.
        try db.execute(sql: #"ALTER TABLE "savedItemSyncTables" ADD COLUMN "isRead" INTEGER NOT NULL DEFAULT 0"#)
        try db.execute(sql: #"ALTER TABLE "savedItemSyncTables" ADD COLUMN "isStarred" INTEGER NOT NULL DEFAULT 0"#)
        try db.execute(sql: #"ALTER TABLE "savedItemSyncTables" ADD COLUMN "deletedAt" TEXT"#)

        // Backfill: anything with a persisted reading position was at least opened.
        try db.execute(sql: #"UPDATE "savedItemSyncTables" SET "isRead" = 1 WHERE "lastReadBlockIndex" IS NOT NULL"#)

        // CloudKit-synced tags. FK-less to match the existing sync table pattern.
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "tagSyncTables" (
              "id" TEXT PRIMARY KEY NOT NULL,
              "name" TEXT NOT NULL DEFAULT '',
              "colorHex" TEXT,
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "itemTagSyncTables" (
              "id" TEXT PRIMARY KEY NOT NULL,
              "itemID" TEXT NOT NULL,
              "tagID" TEXT NOT NULL,
              "createdAt" TEXT NOT NULL
            ) STRICT
            """)

        // Indices for filter/count queries.
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedItemSyncTables_isRead ON "savedItemSyncTables"("isRead")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedItemSyncTables_isStarred ON "savedItemSyncTables"("isStarred")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_savedItemSyncTables_deletedAt ON "savedItemSyncTables"("deletedAt")"#)
        try db.execute(sql: #"CREATE UNIQUE INDEX IF NOT EXISTS idx_tagSyncTables_name ON "tagSyncTables"(LOWER("name"))"#)
        try db.execute(sql: #"CREATE UNIQUE INDEX IF NOT EXISTS idx_itemTagSyncTables_item_tag ON "itemTagSyncTables"("itemID","tagID")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_itemTagSyncTables_itemID ON "itemTagSyncTables"("itemID")"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_itemTagSyncTables_tagID ON "itemTagSyncTables"("tagID")"#)
    }

    /// SQLiteData's `SyncEngine` rejects any CloudKit-synchronized table that
    /// carries a `UNIQUE` constraint outside of the primary key. It refuses
    /// to even start, throwing `SchemaError(.uniquenessConstraint)`, because
    /// two devices could concurrently insert rows that only collide on the
    /// unique column — there's no safe reconciliation on the CloudKit side.
    ///
    /// `migration_v5` created two such indexes on synced tables:
    ///   • `idx_tagSyncTables_name`        on `LOWER(name)`
    ///   • `idx_itemTagSyncTables_item_tag` on `(itemID, tagID)`
    ///
    /// Both were pure defense-in-depth — the repository layer already does
    /// case-insensitive tag-name deduplication in `_createTag` and junction
    /// deduplication in `_addTag` before inserting — so dropping them has no
    /// behavioral impact besides letting the SyncEngine finally start.
    ///
    /// We replace them with non-unique indexes so case-insensitive tag name
    /// lookups and junction reads stay fast.
    private static func migration_v6(_ db: Database) throws {
        try db.execute(sql: #"DROP INDEX IF EXISTS idx_tagSyncTables_name"#)
        try db.execute(sql: #"DROP INDEX IF EXISTS idx_itemTagSyncTables_item_tag"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_tagSyncTables_name_lower ON "tagSyncTables"(LOWER("name"))"#)
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS idx_itemTagSyncTables_item_tag_pair ON "itemTagSyncTables"("itemID","tagID")"#)
    }

    /// Adds cache columns for on-device AI summaries. Both columns are local-
    /// only (the table is not CloudKit-synced) and nullable; summaries stay
    /// nil until the user first requests one in the reader's AI popover.
    private static func migration_v7(_ db: Database) throws {
        try db.execute(sql: #"ALTER TABLE "savedItemContentLocalTables" ADD COLUMN "summary" TEXT"#)
        try db.execute(sql: #"ALTER TABLE "savedItemContentLocalTables" ADD COLUMN "summaryGeneratedAt" TEXT"#)
    }

    /// Adds PDF ingestion support:
    ///   • `pdfSHA256` column on the local content table — used for dedup and
    ///     to find the staged PDF file in temp during post-create placement.
    ///   • A new `savedPDFContentSyncTables` table — CloudKit-synced, carries
    ///     the extracted `documentJSON`/`plainText` for PDF items so a second
    ///     device can hydrate the structured-text view without having the PDF
    ///     bytes (which never sync). Only populated for PDF items.
    private static func migration_v8(_ db: Database) throws {
        try db.execute(sql: #"ALTER TABLE "savedItemContentLocalTables" ADD COLUMN "pdfSHA256" TEXT"#)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "savedPDFContentSyncTables" (
              "id" TEXT PRIMARY KEY NOT NULL,
              "documentJSON" TEXT NOT NULL DEFAULT '',
              "plainText" TEXT NOT NULL DEFAULT '',
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL
            ) STRICT
            """)
    }

    /// v9 — Flexoki-based background + accent color scheme.
    ///
    /// * Adds `primaryAccent` and `secondaryAccent` columns so the user can
    ///   pick a pair of hues from the 8 Flexoki accents.
    /// * Rewrites the legacy `theme` column's string values to the new
    ///   `ReaderBackground` raw values (`white|sepia|dark` → `paper|sepia|black`).
    ///   Pre-v9 users stored on "white" are migrated onto the new warm
    ///   `paper` background so the first post-upgrade open shows the
    ///   intended Flexoki look; anyone who explicitly preferred pure white
    ///   can still flip back via the reader appearance popover.
    private static func migration_v9(_ db: Database) throws {
        try db.execute(sql: #"ALTER TABLE "readerAppearanceSettingsLocalTables" ADD COLUMN "primaryAccent" TEXT NOT NULL DEFAULT 'blue'"#)
        try db.execute(sql: #"ALTER TABLE "readerAppearanceSettingsLocalTables" ADD COLUMN "secondaryAccent" TEXT NOT NULL DEFAULT 'purple'"#)
        try db.execute(sql: #"UPDATE "readerAppearanceSettingsLocalTables" SET "theme" = 'black' WHERE "theme" = 'dark'"#)
        try db.execute(sql: #"UPDATE "readerAppearanceSettingsLocalTables" SET "theme" = 'paper' WHERE "theme" = 'white'"#)
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
