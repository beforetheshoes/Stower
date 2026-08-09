import Dependencies
import Foundation
import SQLiteData

/// Everything the offload feature needs to know about an item's storage
/// state, joined from the item, content, storage, and manifest tables.
public struct ItemStorageInfo: Equatable, Sendable, Identifiable {
    public var itemID: UUID
    public var renderFormat: String
    public var isRead: Bool
    public var isPinned: Bool
    public var lastOpenedAt: Date?
    public var uploadState: String
    public var offloadedAt: Date?
    public var hasCaptureManifest: Bool
    /// Whether the capture's bytes still exist as legacy chunk rows in the
    /// local database (pre-asset-store captures restore from these offline).
    public var hasCaptureChunks = false
    public var assetManifests = [AssetManifest]()

    public var id: UUID { itemID }

    public init(
        itemID: UUID,
        renderFormat: String = "structuredV1",
        isRead: Bool = false,
        isPinned: Bool = false,
        lastOpenedAt: Date? = nil,
        uploadState: String = "pending",
        offloadedAt: Date? = nil,
        hasCaptureManifest: Bool = false,
        hasCaptureChunks: Bool = false,
        assetManifests: [AssetManifest] = []
    ) {
        self.itemID = itemID
        self.renderFormat = renderFormat
        self.isRead = isRead
        self.isPinned = isPinned
        self.lastOpenedAt = lastOpenedAt
        self.uploadState = uploadState
        self.offloadedAt = offloadedAt
        self.hasCaptureManifest = hasCaptureManifest
        self.hasCaptureChunks = hasCaptureChunks
        self.assetManifests = assetManifests
    }
}

/// Database operations for per-item storage state, asset manifests, and the
/// offload policy. The CloudKit side lives in `CloudAssetClient`; this client
/// never leaves SQLite.
public struct ItemStorageClient: Sendable {
    public var upsertManifest: @Sendable (AssetManifest) async throws -> Void
    public var manifest: @Sendable (_ itemID: UUID, _ kind: CloudAssetKind) async throws -> AssetManifest?
    public var manifests: @Sendable (_ itemIDs: [UUID]) async throws -> [AssetManifest]
    public var touchOpened: @Sendable (_ itemID: UUID) async throws -> Void
    public var setPinned: @Sendable (_ itemID: UUID, _ isPinned: Bool) async throws -> Void
    public var setUploadState: @Sendable (_ itemID: UUID, _ state: String) async throws -> Void
    public var setOffloaded: @Sendable (_ itemID: UUID, _ isOffloaded: Bool) async throws -> Void
    public var storageInfo: @Sendable (_ itemID: UUID) async throws -> ItemStorageInfo?
    /// Batched `storageInfo` for library lists.
    public var storageInfosForItems: @Sendable (_ itemIDs: [UUID]) async throws -> [ItemStorageInfo]
    /// All live, read items with their storage state — the eviction service
    /// filters and orders these.
    public var evictionCandidates: @Sendable () async throws -> [ItemStorageInfo]
    public var budgetBytes: @Sendable () async throws -> Int?
    public var setBudgetBytes: @Sendable (Int?) async throws -> Void
    /// Atomically records the manifest and deletes the legacy `zipData` sync
    /// row it replaces. Callers MUST have confirmed the CloudKit upload first
    /// — the deletion propagates to every device.
    public var replaceWebsiteArchiveWithManifest: @Sendable (AssetManifest) async throws -> Void
    /// Live PDF items with no `pdf` asset manifest — upload backfill targets.
    public var pdfItemIDsWithoutManifest: @Sendable () async throws -> [UUID]
    /// Items still carrying a legacy `zipData` sync row — migration targets.
    public var websiteZipItemIDsWithoutManifest: @Sendable () async throws -> [UUID]
    /// Live items whose capture still stores its bytes as chunk rows —
    /// capture-migration targets.
    public var captureItemIDsWithChunks: @Sendable () async throws -> [UUID]
    /// Deletes an item's chunk rows and stamps its capture manifest with
    /// `chunkCount = 0`. Callers MUST have confirmed the asset upload first —
    /// the chunk deletion propagates to every device.
    public var markCaptureMigrated: @Sendable (_ itemID: UUID) async throws -> Void

    public static let noop = Self(
        upsertManifest: { _ in },
        manifest: { _, _ in nil },
        manifests: { _ in [] },
        touchOpened: { _ in },
        setPinned: { _, _ in },
        setUploadState: { _, _ in },
        setOffloaded: { _, _ in },
        storageInfo: { _ in nil },
        storageInfosForItems: { _ in [] },
        evictionCandidates: { [] },
        budgetBytes: { nil },
        setBudgetBytes: { _ in },
        replaceWebsiteArchiveWithManifest: { _ in },
        pdfItemIDsWithoutManifest: { [] },
        websiteZipItemIDsWithoutManifest: { [] },
        captureItemIDsWithChunks: { [] },
        markCaptureMigrated: { _ in }
    )

    public init(
        upsertManifest: @escaping @Sendable (AssetManifest) async throws -> Void,
        manifest: @escaping @Sendable (UUID, CloudAssetKind) async throws -> AssetManifest?,
        manifests: @escaping @Sendable ([UUID]) async throws -> [AssetManifest],
        touchOpened: @escaping @Sendable (UUID) async throws -> Void,
        setPinned: @escaping @Sendable (UUID, Bool) async throws -> Void,
        setUploadState: @escaping @Sendable (UUID, String) async throws -> Void,
        setOffloaded: @escaping @Sendable (UUID, Bool) async throws -> Void,
        storageInfo: @escaping @Sendable (UUID) async throws -> ItemStorageInfo?,
        storageInfosForItems: @escaping @Sendable ([UUID]) async throws -> [ItemStorageInfo],
        evictionCandidates: @escaping @Sendable () async throws -> [ItemStorageInfo],
        budgetBytes: @escaping @Sendable () async throws -> Int?,
        setBudgetBytes: @escaping @Sendable (Int?) async throws -> Void,
        replaceWebsiteArchiveWithManifest: @escaping @Sendable (AssetManifest) async throws -> Void,
        pdfItemIDsWithoutManifest: @escaping @Sendable () async throws -> [UUID],
        websiteZipItemIDsWithoutManifest: @escaping @Sendable () async throws -> [UUID],
        captureItemIDsWithChunks: @escaping @Sendable () async throws -> [UUID],
        markCaptureMigrated: @escaping @Sendable (UUID) async throws -> Void
    ) {
        self.upsertManifest = upsertManifest
        self.manifest = manifest
        self.manifests = manifests
        self.touchOpened = touchOpened
        self.setPinned = setPinned
        self.setUploadState = setUploadState
        self.setOffloaded = setOffloaded
        self.storageInfo = storageInfo
        self.storageInfosForItems = storageInfosForItems
        self.evictionCandidates = evictionCandidates
        self.budgetBytes = budgetBytes
        self.setBudgetBytes = setBudgetBytes
        self.replaceWebsiteArchiveWithManifest = replaceWebsiteArchiveWithManifest
        self.pdfItemIDsWithoutManifest = pdfItemIDsWithoutManifest
        self.websiteZipItemIDsWithoutManifest = websiteZipItemIDsWithoutManifest
        self.captureItemIDsWithChunks = captureItemIDsWithChunks
        self.markCaptureMigrated = markCaptureMigrated
    }
}

extension ItemStorageClient {
    public static func live(database: any DatabaseWriter) -> Self {
        Self(
            upsertManifest: { manifest in
                @Dependency(\.date.now)
                var now
                try await database.write { db in
                    // One manifest per (item, kind): replace any prior row so
                    // a re-upload with new content supersedes the old record.
                    try SavedAssetManifestSyncTable
                        .where { $0.itemID.eq(manifest.itemID) }
                        .where { $0.kind.eq(manifest.kind.rawValue) }
                        .delete()
                        .execute(db)
                    try SavedAssetManifestSyncTable.insert {
                        SavedAssetManifestSyncTable(
                            id: manifest.id,
                            itemID: manifest.itemID,
                            kind: manifest.kind.rawValue,
                            recordName: manifest.recordName,
                            sha256: manifest.sha256,
                            byteCount: manifest.byteCount,
                            originalFilename: manifest.originalFilename,
                            createdAt: now,
                            updatedAt: now
                        )
                    }
                    .execute(db)
                }
            },
            manifest: { itemID, kind in
                try await database.read { db in
                    try SavedAssetManifestSyncTable
                        .where { $0.itemID.eq(itemID) }
                        .where { $0.kind.eq(kind.rawValue) }
                        .fetchOne(db)
                        .flatMap(assetManifest(from:))
                }
            },
            manifests: { itemIDs in
                try await database.read { db in
                    try SavedAssetManifestSyncTable
                        .where { $0.itemID.in(itemIDs) }
                        .fetchAll(db)
                        .compactMap(assetManifest(from:))
                }
            },
            touchOpened: { itemID in
                @Dependency(\.date.now)
                var now
                try await database.write { db in
                    try upsertStorageRow(db, itemID: itemID, now: now) {
                        $0.lastOpenedAt = #bind(now as Date?)
                    }
                }
            },
            setPinned: { itemID, isPinned in
                @Dependency(\.date.now)
                var now
                try await database.write { db in
                    try upsertStorageRow(db, itemID: itemID, now: now) {
                        $0.isPinned = isPinned
                    }
                }
            },
            setUploadState: { itemID, state in
                @Dependency(\.date.now)
                var now
                try await database.write { db in
                    try upsertStorageRow(db, itemID: itemID, now: now) {
                        $0.uploadState = state
                    }
                }
            },
            setOffloaded: { itemID, isOffloaded in
                @Dependency(\.date.now)
                var now
                try await database.write { db in
                    try upsertStorageRow(db, itemID: itemID, now: now) {
                        $0.offloadedAt = #bind(isOffloaded ? now : nil as Date?)
                    }
                }
            },
            storageInfo: { itemID in
                try await database.read { db in
                    try storageInfos(db, itemIDs: [itemID]).first
                }
            },
            storageInfosForItems: { itemIDs in
                try await database.read { db in
                    try storageInfos(db, itemIDs: itemIDs)
                }
            },
            evictionCandidates: {
                try await database.read { db in
                    let readItemIDs = try SavedItemSyncTable
                        .where(\.isRead)
                        .where { $0.deletedAt.is(nil) }
                        .select(\.id)
                        .fetchAll(db)
                    return try storageInfos(db, itemIDs: readItemIDs)
                }
            },
            budgetBytes: {
                try await database.read { db in
                    try StoragePolicyLocalTable
                        .find(StoragePolicyLocalTable.singletonID)
                        .fetchOne(db)?
                        .budgetBytes
                }
            },
            setBudgetBytes: { budget in
                @Dependency(\.date.now)
                var now
                try await database.write { db in
                    try StoragePolicyLocalTable.upsert {
                        StoragePolicyLocalTable.Draft(
                            id: StoragePolicyLocalTable.singletonID,
                            budgetBytes: budget,
                            updatedAt: now
                        )
                    }
                    .execute(db)
                }
            },
            replaceWebsiteArchiveWithManifest: { manifest in
                @Dependency(\.date.now)
                var now
                try await database.write { db in
                    try SavedAssetManifestSyncTable
                        .where { $0.itemID.eq(manifest.itemID) }
                        .where { $0.kind.eq(manifest.kind.rawValue) }
                        .delete()
                        .execute(db)
                    try SavedAssetManifestSyncTable.insert {
                        SavedAssetManifestSyncTable(
                            id: manifest.id,
                            itemID: manifest.itemID,
                            kind: manifest.kind.rawValue,
                            recordName: manifest.recordName,
                            sha256: manifest.sha256,
                            byteCount: manifest.byteCount,
                            originalFilename: manifest.originalFilename,
                            createdAt: now,
                            updatedAt: now
                        )
                    }
                    .execute(db)
                    try SavedWebsiteArchiveSyncTable
                        .find(manifest.itemID)
                        .delete()
                        .execute(db)
                    try upsertStorageRow(db, itemID: manifest.itemID, now: now) {
                        $0.uploadState = "uploaded"
                    }
                }
            },
            pdfItemIDsWithoutManifest: {
                try await database.read { db in
                    let pdfItemIDs = try SavedItemContentLocalTable
                        .where { $0.renderFormat.eq("pdf") }
                        .select(\.itemID)
                        .fetchAll(db)
                    guard !pdfItemIDs.isEmpty else { return [] }
                    let liveIDs = Set(
                        try SavedItemSyncTable
                            .where { $0.id.in(pdfItemIDs) }
                            .where { $0.deletedAt.is(nil) }
                            .select(\.id)
                            .fetchAll(db)
                    )
                    let manifested = Set(
                        try SavedAssetManifestSyncTable
                            .where { $0.kind.eq(CloudAssetKind.pdf.rawValue) }
                            .select(\.itemID)
                            .fetchAll(db)
                    )
                    return pdfItemIDs.filter { liveIDs.contains($0) && !manifested.contains($0) }
                }
            },
            websiteZipItemIDsWithoutManifest: {
                try await database.read { db in
                    let zipItemIDs = try SavedWebsiteArchiveSyncTable
                        .where { $0.byteCount > 0 }
                        .select(\.id)
                        .fetchAll(db)
                    guard !zipItemIDs.isEmpty else { return [] }
                    let liveIDs = Set(
                        try SavedItemSyncTable
                            .where { $0.id.in(zipItemIDs) }
                            .where { $0.deletedAt.is(nil) }
                            .select(\.id)
                            .fetchAll(db)
                    )
                    let manifested = Set(
                        try SavedAssetManifestSyncTable
                            .where { $0.kind.eq(CloudAssetKind.websiteZip.rawValue) }
                            .select(\.itemID)
                            .fetchAll(db)
                    )
                    return zipItemIDs.filter { liveIDs.contains($0) && !manifested.contains($0) }
                }
            },
            captureItemIDsWithChunks: {
                try await database.read { db in
                    let chunkedItemIDs = Set(
                        try SavedArticleCaptureChunkSyncTable
                            .select(\.itemID)
                            .fetchAll(db)
                    )
                    guard !chunkedItemIDs.isEmpty else { return [] }
                    return try SavedItemSyncTable
                        .where { $0.id.in(Array(chunkedItemIDs)) }
                        .where { $0.deletedAt.is(nil) }
                        .select(\.id)
                        .fetchAll(db)
                }
            },
            markCaptureMigrated: { itemID in
                @Dependency(\.date.now)
                var now
                try await database.write { db in
                    try SavedArticleCaptureChunkSyncTable
                        .where { $0.itemID.eq(itemID) }
                        .delete()
                        .execute(db)
                    try SavedArticleCaptureSyncTable
                        .where { $0.itemID.eq(itemID) }
                        .update {
                            $0.chunkCount = 0
                            $0.updatedAt = now
                        }
                        .execute(db)
                }
            }
        )
    }

    private static func upsertStorageRow(
        _ db: Database,
        itemID: UUID,
        now: Date,
        update: (inout Updates<ItemStorageLocalTable>) -> Void
    ) throws {
        let exists = try ItemStorageLocalTable.find(itemID).fetchCount(db) > 0
        if !exists {
            try ItemStorageLocalTable.insert {
                ItemStorageLocalTable(itemID: itemID, updatedAt: now)
            }
            .execute(db)
        }
        try ItemStorageLocalTable
            .find(itemID)
            .update {
                update(&$0)
                $0.updatedAt = now
            }
            .execute(db)
    }

    private static func storageInfos(_ db: Database, itemIDs: [UUID]) throws -> [ItemStorageInfo] {
        guard !itemIDs.isEmpty else { return [] }
        let items = try SavedItemSyncTable
            .where { $0.id.in(itemIDs) }
            .fetchAll(db)
        let contents = try SavedItemContentLocalTable
            .where { $0.itemID.in(itemIDs) }
            .fetchAll(db)
        let storageRows = try ItemStorageLocalTable
            .where { $0.itemID.in(itemIDs) }
            .fetchAll(db)
        let manifestRows = try SavedAssetManifestSyncTable
            .where { $0.itemID.in(itemIDs) }
            .fetchAll(db)
        let captureItemIDs = Set(
            try SavedArticleCaptureSyncTable
                .where { $0.itemID.in(itemIDs) }
                .select(\.itemID)
                .fetchAll(db)
        )
        let chunkedItemIDs = Set(
            try SavedArticleCaptureChunkSyncTable
                .where { $0.itemID.in(itemIDs) }
                .select(\.itemID)
                .fetchAll(db)
        )

        let contentByID = Dictionary(uniqueKeysWithValues: contents.map { ($0.itemID, $0) })
        let storageByID = Dictionary(uniqueKeysWithValues: storageRows.map { ($0.itemID, $0) })
        let manifestsByID = Dictionary(grouping: manifestRows.compactMap(assetManifest(from:)), by: \.itemID)

        return items.map { item in
            let storage = storageByID[item.id]
            return ItemStorageInfo(
                itemID: item.id,
                renderFormat: contentByID[item.id]?.renderFormat ?? "structuredV1",
                isRead: item.isRead,
                isPinned: storage?.isPinned ?? false,
                lastOpenedAt: storage?.lastOpenedAt,
                uploadState: storage?.uploadState ?? "pending",
                offloadedAt: storage?.offloadedAt,
                hasCaptureManifest: captureItemIDs.contains(item.id),
                hasCaptureChunks: chunkedItemIDs.contains(item.id),
                assetManifests: manifestsByID[item.id] ?? []
            )
        }
    }

    private static func assetManifest(from row: SavedAssetManifestSyncTable) -> AssetManifest? {
        guard let kind = CloudAssetKind(rawValue: row.kind) else { return nil }
        return AssetManifest(
            id: row.id,
            itemID: row.itemID,
            kind: kind,
            recordName: row.recordName,
            sha256: row.sha256,
            byteCount: row.byteCount,
            originalFilename: row.originalFilename
        )
    }
}

// MARK: - Dependency Key

private enum ItemStorageClientKey: DependencyKey {
    static let liveValue: ItemStorageClient = .noop
    static let testValue: ItemStorageClient = .noop
}

extension DependencyValues {
    public var itemStorageClient: ItemStorageClient {
        get { self[ItemStorageClientKey.self] }
        set { self[ItemStorageClientKey.self] = newValue }
    }
}
