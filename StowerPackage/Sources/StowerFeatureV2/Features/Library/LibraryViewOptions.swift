import Foundation

public enum LibraryDisplayStyle: String, CaseIterable, Equatable, Sendable {
    case compact = "compact"
    case expanded = "expanded"

    public var title: String {
        switch self {
        case .compact:
            "Compact"
        case .expanded:
            "Expanded"
        }
    }
}

public enum LibrarySortOrder: String, CaseIterable, Equatable, Sendable {
    case newestFirst = "newestFirst"
    case oldestFirst = "oldestFirst"

    public var title: String {
        switch self {
        case .newestFirst:
            "Newest Saved"
        case .oldestFirst:
            "Oldest Saved"
        }
    }
}
