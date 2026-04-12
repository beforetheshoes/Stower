import Foundation

public enum TextImportMode: String, Codable, CaseIterable, Equatable, Sendable {
    case plainText = "plainText"
    case markdown = "markdown"
    case auto = "auto"
}

public struct QueuedTextPayload: Codable, Equatable, Sendable {
    public var content: String
    public var titleHint: String?
    public var mode: TextImportMode

    public init(content: String, mode: TextImportMode, titleHint: String? = nil) {
        self.content = content
        self.titleHint = titleHint
        self.mode = mode
    }
}

public enum TextImportDetector {
    public static func looksLikeMarkdown(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let patterns = [
            #"(?m)^\s{0,3}#{1,6}\s+\S"#,
            #"(?m)^\s{0,3}[-*+]\s+\S"#,
            #"(?m)^\s{0,3}\d+\.\s+\S"#,
            #"(?m)^\s{0,3}>\s+\S"#,
            #"(?m)^\s{0,3}(```|~~~)"#,
            #"(?m)^\s{0,3}([-*_])(\s*\1){2,}\s*$"#,
            #"(?s)\|.+\|\s*\n\s*\|[\s:\-]+\|"#,
            #"\[[^\]]+\]\([^)]+\)"#,
        ]

        return patterns.contains { pattern in
            trimmed.range(of: pattern, options: .regularExpression) != nil
        }
    }

    public static func inferredMode(for text: String, preferred preferredMode: TextImportMode) -> TextImportMode {
        switch preferredMode {
        case .plainText, .markdown:
            return preferredMode
        case .auto:
            return looksLikeMarkdown(text) ? .markdown : .plainText
        }
    }

    public static func importMode(for fileURL: URL) -> TextImportMode? {
        switch fileURL.pathExtension.lowercased() {
        case "md", "markdown":
            return .markdown
        case "txt":
            return .auto
        default:
            return nil
        }
    }

    public static func normalizedTitleHint(from fileURL: URL) -> String? {
        let name = fileURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

public enum QueuedTextPayloadCodec {
    public static func encode(_ payload: QueuedTextPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    public static func decode(_ raw: String, defaultMode: TextImportMode) -> QueuedTextPayload {
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(QueuedTextPayload.self, from: data)
        else {
            return QueuedTextPayload(content: raw, mode: defaultMode)
        }
        return payload
    }
}

public enum SharedTextClassifier {
    public enum Result: Equatable, Sendable {
        case singleURL(URL)
        case text(QueuedTextPayload)
    }

    public static func classify(_ text: String) -> Result {
        if let url = singleURL(in: text) {
            return .singleURL(url)
        }
        return .text(QueuedTextPayload(content: text, mode: .auto))
    }

    public static func singleURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        guard let match = detector?.firstMatch(in: trimmed, options: [], range: range),
              match.range == range
        else {
            return nil
        }
        return match.url
    }
}

public func resolvedTextImportTitle(documentTitle: String?, titleHint: String?) -> String {
    if let documentTitle {
        let trimmed = documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    if let titleHint {
        let trimmed = titleHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    return "Shared Note"
}
