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

/// Counts for every sidebar list, produced in a single repository read so the
/// sidebar can render accurate badges without fanning out N queries per tag.
public struct LibraryListCounts: Equatable, Sendable {
    public var unread: Int
    public var read: Int
    public var starred: Int
    public var untagged: Int
    public var all: Int
    public var recentlyDeleted: Int
    public var byTag: [UUID: Int] // swiftlint:disable:this prefer_let_over_var

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
