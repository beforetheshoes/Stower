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


/// The kinds of file the library can import through a document picker.
public enum LibraryImportPicker: String, Identifiable, Equatable, Sendable {
    case text = "text"
    case pdf = "pdf"
    case epub = "epub"
    case website = "website"

    public var id: String { rawValue }
}
