import Foundation
import StowerData
import Testing

@Suite
struct ReaderDocumentSanitizerTests {
    // The sanitizer runs on every reader-document load from persistence.
    // If it trims the boundary whitespace the parser carefully preserved
    // on `.text` segments, inline links/bold/code render smooshed against
    // their neighbours. These tests pin down that invariant.

    private func concatenated(_ inlines: [ReaderInline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let value):
                return value
            case .link(let label, _):
                return label
            case .emphasis(let value):
                return value
            case .strong(let value):
                return value
            case .code(let value):
                return value
            case .strikethrough(let value):
                return value
            }
        }
        .joined()
    }

    private func sanitizedParagraph(_ inlines: [ReaderInline]) -> [ReaderInline] {
        guard case .paragraph(let result) = sanitizeLoadedBlocks([.paragraph(inlines)])[0] else {
            return []
        }
        return result
    }

    @Test
    func preservesTrailingSpaceOnTextSegmentBeforeLink() {
        let input: [ReaderInline] = [
            .text("word "),
            .link(label: "link", url: "https://example.com"),
            .text(" text"),
        ]
        let result = sanitizedParagraph(input)
        #expect(concatenated(result) == "word link text")
    }

    @Test
    func preservesSpaceAroundStrongSegment() {
        let input: [ReaderInline] = [
            .text("a "),
            .strong("bold"),
            .text(" b"),
        ]
        let result = sanitizedParagraph(input)
        #expect(concatenated(result) == "a bold b")
    }

    @Test
    func doesNotFabricateSpaceWhenSegmentsWereContiguous() {
        let input: [ReaderInline] = [
            .text("a"),
            .strong("bold"),
            .text("b"),
        ]
        let result = sanitizedParagraph(input)
        #expect(concatenated(result) == "aboldb")
    }

    @Test
    func stillTrimsEmphasisAndStrongLabels() {
        // Boundary whitespace belongs on `.text` segments, not on the
        // labels of formatting elements. The sanitizer should trim the
        // labels so "bold" doesn't accidentally become " bold ".
        let input: [ReaderInline] = [
            .text("a "),
            .strong(" bold "),
            .text(" b"),
        ]
        let result = sanitizedParagraph(input)
        #expect(concatenated(result) == "a bold b")
    }

    @Test
    func stripsPilcrowsWithoutLosingBoundarySpace() {
        let input: [ReaderInline] = [
            .text("word\u{00B6} "),
            .link(label: "link", url: "https://example.com"),
            .text(" tail"),
        ]
        let result = sanitizedParagraph(input)
        #expect(concatenated(result) == "word link tail")
    }

    @Test
    func collapsesDoubleSpaceAtMergedTextSeam() {
        // Two adjacent text segments each carrying boundary space should
        // merge into a single space, not a double space.
        let input: [ReaderInline] = [
            .text("alpha "),
            .text(" beta"),
        ]
        let result = sanitizedParagraph(input)
        #expect(concatenated(result) == "alpha beta")
    }
}
