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

extension LibraryImportPicker {
    /// How the file is named in "Couldn't read …" messages.
    var fileNoun: String {
        switch self {
        case .text:
            "text file"
        case .pdf:
            "PDF"
        case .epub:
            "EPUB"
        case .website:
            "zip"
        }
    }

    /// How the import is named in "… import failed" messages.
    var importNoun: String {
        switch self {
        case .text:
            "Text"
        case .pdf:
            "PDF"
        case .epub:
            "EPUB"
        case .website:
            "Website"
        }
    }
}

extension LibraryImportPicker {
    /// The import a dropped file should go through, by its extension.
    init?(droppedFile url: URL) {
        switch url.pathExtension.lowercased() {
        case "pdf":
            self = .pdf
        case "epub":
            self = .epub
        case "zip":
            self = .website
        case "md", "markdown", "txt":
            self = .text
        default:
            return nil
        }
    }
}
