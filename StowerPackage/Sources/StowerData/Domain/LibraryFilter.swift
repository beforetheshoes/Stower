import Foundation

/// Which subset of the library to display in the list column.
///
/// Backed by explicit flags on `SavedItemSyncTable` plus the many-to-many
/// tag junction, so every filter maps to a concrete SQL query in the
/// repository layer.
public enum LibraryFilter: Equatable, Hashable, Sendable, Codable {
    case all
    case unread
    case read
    case starred
    case untagged
    case recentlyDeleted
    case tag(UUID)
}

extension LibraryFilter {
    /// A stable string form for remembering the selected list between
    /// launches. Recently Deleted is not remembered: reopening the app in
    /// the trash would be a surprise.
    public var storageKey: String {
        switch self {
        case .all, .recentlyDeleted:
            "all"
        case .unread:
            "unread"
        case .read:
            "read"
        case .starred:
            "starred"
        case .untagged:
            "untagged"
        case .tag(let id):
            "tag:\(id.uuidString)"
        }
    }

    public init?(storageKey: String) {
        switch storageKey {
        case "all":
            self = .all
        case "unread":
            self = .unread
        case "read":
            self = .read
        case "starred":
            self = .starred
        case "untagged":
            self = .untagged
        default:
            guard storageKey.hasPrefix("tag:"),
                  let id = UUID(uuidString: String(storageKey.dropFirst(4)))
            else { return nil }
            self = .tag(id)
        }
    }
}

/// Counts for every sidebar list, produced in a single repository read so the
/// sidebar can render accurate badges without fanning out N queries per tag.
public struct LibraryListCounts: Equatable, Sendable {
    public var unread: Int
    public var read: Int
    public var starred: Int
    public var untagged: Int
    public var all: Int
    public var recentlyDeleted: Int
    public var byTag = [UUID: Int]()

    public init(
        unread: Int = 0,
        read: Int = 0,
        starred: Int = 0,
        untagged: Int = 0,
        all: Int = 0,
        recentlyDeleted: Int = 0,
        byTag: [UUID: Int] = [:]
    ) {
        self.unread = unread
        self.read = read
        self.starred = starred
        self.untagged = untagged
        self.all = all
        self.recentlyDeleted = recentlyDeleted
        self.byTag = byTag
    }

    public static let zero = LibraryListCounts()
}
