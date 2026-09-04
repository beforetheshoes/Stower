import Foundation
import SQLiteData

// MARK: - Light content projection

/// The handful of local-content columns the library list needs. Selecting
/// this instead of the full row keeps `sourceHTML`, `documentJSON`, and
/// `plainText` out of every list fetch.
@Selection
public struct SavedItemContentMeta: Equatable, Sendable {
    public var itemID: UUID
    public var renderFormat: String
    public var documentVersion: Int
    public var captureVersion: Int
    public var localStatus: String
    public var localError: String?
    public var progressUnitCount: Int?
}

// MARK: - Library request

/// Everything the library list observes, fetched in one read transaction so
/// rows, tags, and storage badges change together.
public struct LibraryRequest: FetchKeyRequest {
    public struct Value: Equatable, Sendable {
        public let items: [SavedItem]
        public let tags: [Tag]
        public let storageInfoByID: [UUID: ItemStorageInfo]

        public init(
            items: [SavedItem] = [],
            tags: [Tag] = [],
            storageInfoByID: [UUID: ItemStorageInfo] = [:]
        ) {
            self.items = items
            self.tags = tags
            self.storageInfoByID = storageInfoByID
        }
    }

    public var filter: LibraryFilter
    public var query: String
    public var oldestFirst: Bool

    public init(filter: LibraryFilter, query: String = "", oldestFirst: Bool = false) {
        self.filter = filter
        self.query = query
        self.oldestFirst = oldestFirst
    }

    public func fetch(_ db: Database) throws -> Value {
        let items = try LibraryQueries.fetchItems(
            db,
            filter: filter,
            query: query,
            oldestFirst: oldestFirst
        )
        let tags = try LibraryQueries.fetchTags(db)
        let storage = try ItemStorageClient.storageInfos(db, itemIDs: items.map(\.id))
        return Value(
            items: items,
            tags: tags,
            storageInfoByID: Dictionary(uniqueKeysWithValues: storage.map { ($0.itemID, $0) })
        )
    }
}

// MARK: - Sidebar request

/// List counts and the tag list, observed together for the sidebar.
public struct SidebarRequest: FetchKeyRequest {
    public struct Value: Equatable, Sendable {
        public let counts: LibraryListCounts
        public let tags: [Tag]

        public init(counts: LibraryListCounts = .zero, tags: [Tag] = []) {
            self.counts = counts
            self.tags = tags
        }
    }

    public init() {}

    public func fetch(_ db: Database) throws -> Value {
        Value(
            counts: try LibraryQueries.fetchListCounts(db),
            tags: try LibraryQueries.fetchTags(db)
        )
    }
}

// MARK: - Shared query implementations

public enum LibraryQueries {
    /// Library rows for a filter, optionally narrowed by a search string.
    ///
    /// Search runs in SQL against title, URL, site, author, excerpt and the
    /// extracted body text. Body text is returned on matched rows only, so
    /// the view can show a snippet without holding every article in memory.
    public static func fetchItems(
        _ db: Database,
        filter: LibraryFilter,
        query: String,
        oldestFirst: Bool
    ) throws -> [SavedItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let synced = try fetchSyncRows(
            db,
            filter: filter,
            query: trimmedQuery,
            oldestFirst: oldestFirst
        )

        // Collapse duplicates that share a canonical URL, keeping the first
        // (newest, or oldest when reversed) so selection indexes stay stable.
        var seen = Set<String>()
        let unique = synced.filter { row in
            guard let key = StowerRepository.normalizedURLKey(row.canonicalURL ?? row.sourceURL) else {
                return true
            }
            return seen.insert(key).inserted
        }

        let ids = unique.map(\.id)
        guard !ids.isEmpty else { return [] }

        let metas = try contentMetas(db, itemIDs: ids)
        let metaByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.itemID, $0) })

        let junctions = try ItemTagSyncTable
            .where { $0.itemID.in(ids) }
            .fetchAll(db)
        let tagIDsByItem = junctions.reduce(into: [UUID: [UUID]]()) { result, row in
            result[row.itemID, default: []].append(row.tagID)
        }

        // Only searches need body text, and only for the rows that matched.
        var contentByID = [UUID: String]()
        if !trimmedQuery.isEmpty {
            let texts = try SavedItemContentLocalTable
                .where { $0.itemID.in(ids) }
                .select { ($0.itemID, $0.plainText) }
                .fetchAll(db)
            contentByID = Dictionary(uniqueKeysWithValues: texts)
        }

        return unique.map { row in
            StowerRepository.toDomain(
                sync: row,
                meta: metaByID[row.id],
                tagIDs: tagIDsByItem[row.id] ?? [],
                content: contentByID[row.id] ?? ""
            )
        }
    }

    /// The light content projection for a batch of items.
    static func contentMetas(_ db: Database, itemIDs: [UUID]) throws -> [SavedItemContentMeta] {
        guard !itemIDs.isEmpty else { return [] }
        return try SavedItemContentLocalTable
            .where { $0.itemID.in(itemIDs) }
            .select {
                SavedItemContentMeta.Columns(
                    itemID: $0.itemID,
                    renderFormat: $0.renderFormat,
                    documentVersion: $0.documentVersion,
                    captureVersion: $0.captureVersion,
                    localStatus: $0.localStatus,
                    localError: $0.localError,
                    progressUnitCount: $0.progressUnitCount
                )
            }
            .fetchAll(db)
    }

    public static func fetchTags(_ db: Database) throws -> [Tag] {
        try TagSyncTable
            .order { $0.name }
            .fetchAll(db)
            .map(StowerRepository.toDomain(tag:))
    }

    public static func fetchListCounts(_ db: Database) throws -> LibraryListCounts {
        let allCount = try SavedItemSyncTable
            .where { $0.deletedAt.is(nil) }
            .fetchCount(db)
        let unreadCount = try SavedItemSyncTable
            .where { $0.deletedAt.is(nil) && !$0.isRead }
            .fetchCount(db)
        let readCount = try SavedItemSyncTable
            .where { $0.deletedAt.is(nil) && $0.isRead }
            .fetchCount(db)
        let starredCount = try SavedItemSyncTable
            .where { $0.deletedAt.is(nil) && $0.isStarred }
            .fetchCount(db)
        let trashCount = try SavedItemSyncTable
            .where { $0.deletedAt.isNot(nil) }
            .fetchCount(db)
        let untaggedCount = try SavedItemSyncTable
            .where { $0.deletedAt.is(nil) && !$0.id.in(ItemTagSyncTable.select(\.itemID)) }
            .fetchCount(db)

        // Per-tag counts over live items only.
        let liveIDs = Set(
            try SavedItemSyncTable
                .where { $0.deletedAt.is(nil) }
                .select(\.id)
                .fetchAll(db)
        )
        let byTag = try ItemTagSyncTable.all
            .fetchAll(db)
            .filter { liveIDs.contains($0.itemID) }
            .reduce(into: [UUID: Int]()) { result, row in
                result[row.tagID, default: 0] += 1
            }

        return LibraryListCounts(
            unread: unreadCount,
            read: readCount,
            starred: starredCount,
            untagged: untaggedCount,
            all: allCount,
            recentlyDeleted: trashCount,
            byTag: byTag
        )
    }

    // MARK: Private

    private static func fetchSyncRows(
        _ db: Database,
        filter: LibraryFilter,
        query: String,
        oldestFirst: Bool
    ) throws -> [SavedItemSyncTable] {
        var rows: Where<SavedItemSyncTable>
        switch filter {
        case .all:
            rows = SavedItemSyncTable.where { $0.deletedAt.is(nil) }
        case .unread:
            rows = SavedItemSyncTable.where { $0.deletedAt.is(nil) && !$0.isRead }
        case .read:
            rows = SavedItemSyncTable.where { $0.deletedAt.is(nil) && $0.isRead }
        case .starred:
            rows = SavedItemSyncTable.where { $0.deletedAt.is(nil) && $0.isStarred }
        case .recentlyDeleted:
            rows = SavedItemSyncTable.where { $0.deletedAt.isNot(nil) }
        case .untagged:
            rows = SavedItemSyncTable.where {
                $0.deletedAt.is(nil) && !$0.id.in(ItemTagSyncTable.select(\.itemID))
            }
        case .tag(let tagID):
            rows = SavedItemSyncTable.where {
                $0.deletedAt.is(nil)
                    && $0.id.in(ItemTagSyncTable.where { $0.tagID.eq(tagID) }.select(\.itemID))
            }
        }

        if !query.isEmpty {
            let pattern = "%" + escapeLikePattern(query) + "%"
            rows = rows.where {
                $0.title.like(pattern, escape: "\\")
                    || ($0.sourceURL ?? "").like(pattern, escape: "\\")
                    || ($0.siteName ?? "").like(pattern, escape: "\\")
                    || ($0.author ?? "").like(pattern, escape: "\\")
                    || ($0.excerpt ?? "").like(pattern, escape: "\\")
                    || $0.id.in(
                        SavedItemContentLocalTable
                            .where { $0.plainText.like(pattern, escape: "\\") }
                            .select(\.itemID)
                    )
            }
        }

        switch (filter, oldestFirst) {
        case (.recentlyDeleted, false):
            return try rows.order { $0.deletedAt.desc() }.fetchAll(db)
        case (.recentlyDeleted, true):
            return try rows.order { $0.deletedAt }.fetchAll(db)
        case (_, false):
            return try rows.order { $0.createdAt.desc() }.fetchAll(db)
        case (_, true):
            return try rows.order { $0.createdAt }.fetchAll(db)
        }
    }

    /// Escapes `%`, `_`, and the escape character so user input matches
    /// literally inside a LIKE pattern.
    static func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
