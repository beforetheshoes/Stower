import Foundation
import StowerData

/// One row of the reader's table of contents: a heading in the document.
public struct ReaderContentsEntry: Equatable, Identifiable, Sendable {
    public var blockIndex: Int
    /// Nesting depth for display, starting at 0 for the shallowest heading
    /// level the document uses.
    public var depth: Int
    public var title: String

    public var id: Int { blockIndex }

    /// Fewer headings than this and a table of contents is not worth a
    /// toolbar button.
    static let minimumEntryCount = 3

    /// The document's headings, in order. Depth is relative to the
    /// shallowest level present, so a book whose chapters are all `h2`
    /// does not render with every row indented.
    static func entries(for document: ReaderDocument?) -> [ReaderContentsEntry] {
        guard let document else { return [] }
        let headings = document.blocks.enumerated().compactMap { index, block -> (Int, Int, String)? in
            guard case let .heading(level, inlines) = block else { return nil }
            let title = ReaderTextLayoutSupport.inlinePlainText(from: inlines)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : (index, level, title)
        }
        guard headings.count >= minimumEntryCount,
              let shallowest = headings.map(\.1).min()
        else { return [] }
        return headings.map { index, level, title in
            ReaderContentsEntry(blockIndex: index, depth: min(level - shallowest, 3), title: title)
        }
    }
}

/// A request for the reader page to jump to a block. `sequence` makes two
/// requests for the same block distinct, so tapping the same contents row
/// twice scrolls twice.
public struct ReaderScrollRequest: Equatable, Sendable {
    public var sequence: Int
    public var blockIndex: Int
}
