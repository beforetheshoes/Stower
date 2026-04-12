import Foundation
@testable import StowerFeature
import Testing

@Suite
struct ReaderTextLayoutSupportTests {
    @Test
    func inlineBuilder_doesNotAddTrailingOrDuplicateWhitespace() {
        let inlines: [ReaderInline] = [
            .text("Hello"),
            .strong("world"),
            .emphasis("again"),
        ]

        let output = ReaderTextLayoutSupport.makeInlineAttributedString(from: inlines)
        let rendered = String(output.characters)

        #expect(rendered == "Hello world again")
        #expect(!rendered.hasSuffix(" "))
        #expect(!rendered.contains("  "))
    }

    @Test
    func inlineBuilder_preservesLinkAndStyleAttributes() {
        let inlines: [ReaderInline] = [
            .text("Start"),
            .link(label: "site", url: "https://example.com"),
            .emphasis("em"),
            .strong("strong"),
            .code("code"),
            .strikethrough("strike"),
        ]
        let attributed = ReaderTextLayoutSupport.makeInlineAttributedString(from: inlines)
        let rendered = String(attributed.characters)
        let ns = NSAttributedString(attributed)
        let nsRendered = rendered as NSString

        let linkRange = nsRendered.range(of: "site")

        #expect(linkRange.location != NSNotFound)
        let link = ns.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
        #expect(link?.absoluteString == "https://example.com")

        let hasInlineIntent = attributed.runs.contains { $0.inlinePresentationIntent != nil }
        let hasStrikethrough = attributed.runs.contains { $0.strikethroughStyle != nil }
        #expect(hasInlineIntent)
        #expect(hasStrikethrough)
    }

    @Test
    func measuredHeight_isFinitePositiveAndMonotonicWithWidth() {
        let text = NSAttributedString(
            string: "This is a long paragraph intended to wrap across multiple lines in narrow widths and fewer lines in wide widths."
        )

        let narrow = ReaderTextLayoutSupport.measuredHeight(for: text, width: 220)
        let wide = ReaderTextLayoutSupport.measuredHeight(for: text, width: 520)

        #expect(narrow > 0)
        #expect(wide > 0)
        #expect(narrow.isFinite)
        #expect(wide.isFinite)
        #expect(narrow >= wide)
    }

    @Test
    func measuredHeight_isStableAcrossRepeatedCalls() {
        let text = NSAttributedString(string: String(repeating: "Stable layout measurement. ", count: 20))

        let first = ReaderTextLayoutSupport.measuredHeight(for: text, width: 360)
        let second = ReaderTextLayoutSupport.measuredHeight(for: text, width: 360)
        let third = ReaderTextLayoutSupport.measuredHeight(for: text, width: 360)

        #expect(first == second)
        #expect(second == third)
    }

    @Test
    func measuredHeight_handlesRepresentativeReaderContent() {
        let paragraph = NSAttributedString(string: "Paragraph text with enough words to wrap naturally over several lines.")
        let list = NSAttributedString(string: "1. First item with details that wrap onto additional lines.")
        let blockquote = NSAttributedString(string: "“Quoted text that should remain readable and produce a bounded height.”")

        let paragraphHeight = ReaderTextLayoutSupport.measuredHeight(for: paragraph, width: 680)
        let listHeight = ReaderTextLayoutSupport.measuredHeight(for: list, width: 680)
        let quoteHeight = ReaderTextLayoutSupport.measuredHeight(for: blockquote, width: 680)

        #expect(paragraphHeight > 0 && paragraphHeight < 10_000)
        #expect(listHeight > 0 && listHeight < 10_000)
        #expect(quoteHeight > 0 && quoteHeight < 10_000)
    }

    @Test
    func layoutWidths_handleProposalFallbackAndDefault() {
        let proposed = ReaderTextLayoutSupport.layoutWidths(proposedWidth: 500, fallbackWidth: 420)
        let missing = ReaderTextLayoutSupport.layoutWidths(proposedWidth: nil, fallbackWidth: 420)
        let invalid = ReaderTextLayoutSupport.layoutWidths(proposedWidth: .nan, fallbackWidth: 410)
        let defaulted = ReaderTextLayoutSupport.layoutWidths(proposedWidth: nil, fallbackWidth: nil)

        #expect(proposed.reported == 500)
        #expect(proposed.measurement == 500)
        #expect(missing.reported == 0)
        #expect(missing.measurement == 420)
        #expect(invalid.reported == 0)
        #expect(invalid.measurement == 410)
        #expect(defaulted.reported == 0)
        #expect(defaulted.measurement == 320)
    }
}
