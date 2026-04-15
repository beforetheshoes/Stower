import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct TextAuthoringSheetTests {
    @Test
    func explicitMarkdownModeUsesMarkdownPreview() {
        #expect(
            TextAuthoringPreviewSupport.kind(
                for: "# Heading\n\nBody",
                mode: .markdown
            ) == .markdown
        )
    }

    @Test
    func autoModeUsesMarkdownPreviewForMarkdownLikeInput() {
        #expect(
            TextAuthoringPreviewSupport.kind(
                for: "# Heading\n\n- one\n- two",
                mode: .auto
            ) == .markdown
        )
    }

    @Test
    func autoModeUsesPlainTextPreviewForProse() {
        #expect(
            TextAuthoringPreviewSupport.kind(
                for: "Normal prose with a link https://example.com in it.",
                mode: .auto
            ) == .plainText
        )
    }

    @Test
    func explicitPlainTextModeUsesPlainTextPreview() {
        #expect(
            TextAuthoringPreviewSupport.kind(
                for: "# Not markdown here",
                mode: .plainText
            ) == .plainText
        )
    }

    @Test
    func markdownPreviewHTMLUsesReaderRenderingForBlockquotesAndInlineCode() {
        let html = TextAuthoringPreviewSupport.previewHTML(
            text: """
            > Quote with `inline code`
            """,
            title: "",
            mode: .markdown
        )

        #expect(html.contains("<blockquote"))
        #expect(html.contains("<code>inline code</code>"))
    }
}
