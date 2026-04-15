import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct TextImportSupportTests {
    @Test
    func markdownMode_buildsStructuredDocumentWithSupportedBlocks() async throws {
        let source = """
        # Markdown Title

        Lead paragraph with *emphasis*, **strong text**, `inline code`, ~~strike~~, and [a link](https://example.com).

        > Quoted line

        - First item
        - Second item

        ```swift
        let value = 42
        ```

        | Name | Value |
        | --- | --- |
        | One | 1 |

        ---
        """

        let result = try await TextIngestionClient.live.ingest(source, nil, nil, .markdown)

        #expect(result.title == "Markdown Title")
        #expect(result.renderFormat == .structuredV1)
        #expect(result.document.blocks.contains { block in
            if case .heading(level: 1, inlines: let inlines) = block {
                return inlines == [ReaderInline.text("Markdown Title")]
            }
            return false
        })
        #expect(result.document.blocks.contains { block in
            if case .paragraph(let inlines) = block {
                return inlines.contains(.emphasis("emphasis"))
                    && inlines.contains(.strong("strong text"))
                    && inlines.contains(.code("inline code"))
                    && inlines.contains(.strikethrough("strike"))
                    && inlines.contains(.link(label: "a link", url: "https://example.com"))
            }
            return false
        })
        #expect(result.document.blocks.contains { block in
            if case .blockquote(let inlines) = block {
                return inlines == [.text("Quoted line")]
            }
            return false
        })
        #expect(result.document.blocks.contains { block in
            if case .list(ordered: false, items: let items) = block {
                return items.count == 2
                    && items[0] == [.text("First item")]
                    && items[1] == [.text("Second item")]
            }
            return false
        })
        #expect(result.document.blocks.contains { block in
            if case .code(language: "swift", code: let code) = block {
                return code == "let value = 42"
            }
            return false
        })
        #expect(result.document.blocks.contains { block in
            if case .table(let markdown) = block {
                return markdown.contains("| Name | Value |")
            }
            return false
        })
        #expect(result.document.blocks.contains { block in
            if case .horizontalRule = block {
                return true
            }
            return false
        })
        #expect(result.plainText.contains("Lead paragraph with emphasis, strong text, inline code, strike, and a link."))
    }

    @Test
    func titleFallsBackToHintWhenMarkdownHasNoH1() async throws {
        let result = try await TextIngestionClient.live.ingest("Body text only", nil, "Meeting Notes", .markdown)

        #expect(result.title == "Meeting Notes")
    }

    @Test
    func plainTextFallsBackToSharedNoteWhenNoTitleHintExists() async throws {
        let result = try await TextIngestionClient.live.ingest("Just plain text", nil, nil, .plainText)

        #expect(result.title == "Shared Note")
        #expect(result.renderFormat == .plainText)
        #expect(result.document.blocks == [.paragraph([.text("Just plain text")])])
    }

    @Test
    func manualTitleOverridesMarkdownH1() async throws {
        let result = try await TextIngestionClient.live.ingest(
            "# Original Heading",
            "Manual Title",
            nil,
            .markdown
        )

        #expect(result.title == "Manual Title")
    }

    @Test
    func plainTextPreservesParagraphsAndLineBreaks() async throws {
        let result = try await TextIngestionClient.live.ingest(
            "First line\nSecond line\n\nThird paragraph",
            nil,
            nil,
            .plainText
        )

        #expect(result.document.blocks == [
            .paragraph([.text("First line"), .lineBreak, .text("Second line")]),
            .paragraph([.text("Third paragraph")]),
        ])
        #expect(result.plainText == "First line\nSecond line\n\nThird paragraph")
    }

    @Test
    func markdownHardBreaksRemainVisible() async throws {
        let result = try await TextIngestionClient.live.ingest(
            "Line one  \nLine two",
            nil,
            nil,
            .markdown
        )

        #expect(result.document.blocks == [
            .paragraph([.text("Line one"), .lineBreak, .text("Line two")]),
        ])
    }

    @Test
    func autoMode_detectsMarkdownLikeContent() async throws {
        let result = try await TextIngestionClient.live.ingest(
            """
            # Heading

            - one
            - two
            """,
            nil,
            nil,
            .auto
        )

        #expect(result.renderFormat == .structuredV1)
        #expect(result.title == "Heading")
    }

    @Test
    func autoMode_keepsPlainProseAsPlainText() async throws {
        let result = try await TextIngestionClient.live.ingest(
            "This is a normal paragraph with a https://example.com link inside it.",
            nil,
            nil,
            .auto
        )

        #expect(result.renderFormat == .plainText)
        #expect(result.title == "Shared Note")
    }

    // MARK: - looksLikeMarkdown inline detection

    @Test
    func looksLikeMarkdown_detectsBoldSyntax() {
        #expect(TextImportDetector.looksLikeMarkdown("This has **bold** text"))
    }

    @Test
    func looksLikeMarkdown_detectsInlineCode() {
        #expect(TextImportDetector.looksLikeMarkdown("Use `let x = 1` in Swift"))
    }

    @Test
    func looksLikeMarkdown_rejectsPlainProse() {
        #expect(!TextImportDetector.looksLikeMarkdown("This is a normal paragraph with no formatting."))
    }

    @Test
    func looksLikeMarkdown_rejectsAsterisksInMath() {
        #expect(!TextImportDetector.looksLikeMarkdown("2 * 3 = 6"))
    }

    @Test
    func inferredMode_autoFallsBackToAutoDetection() {
        let mode = TextImportDetector.inferredMode(
            for: "# Heading\n\nSome text",
            preferred: .auto
        )
        #expect(mode == .markdown)
    }

    @Test
    func inferredMode_autoDetectsPlainText() {
        let mode = TextImportDetector.inferredMode(
            for: "Just a plain sentence.",
            preferred: .auto
        )
        #expect(mode == .plainText)
    }

    @Test
    func autoMode_detectsInlineOnlyMarkdown() async throws {
        let result = try await TextIngestionClient.live.ingest(
            "This has **bold** and `code` but no headings or lists.",
            nil,
            nil,
            .auto
        )

        #expect(result.renderFormat == .structuredV1)
    }

    @Test
    func unsupportedNestedMarkdown_degradesToReadableText() async throws {
        let result = try await TextIngestionClient.live.ingest(
            """
            - Parent
              - Child
            """,
            nil,
            nil,
            .markdown
        )

        #expect(!result.document.blocks.isEmpty)
        #expect(result.plainText.contains("Parent"))
        #expect(result.plainText.contains("Child"))
    }

    // MARK: - Markdown reconstruction (ReaderDocumentMarkdownWriter)

    @Test
    func markdownWriter_reconstructsHeadings() {
        let document = ReaderDocument(title: "Test", blocks: [
            .heading(level: 1, inlines: [.text("Title")]),
            .heading(level: 2, inlines: [.text("Section")]),
        ])
        let md = ReaderDocumentMarkdownWriter.markdown(from: document)
        #expect(md.contains("# Title"))
        #expect(md.contains("## Section"))
    }

    @Test
    func markdownWriter_reconstructsInlineFormatting() {
        let document = ReaderDocument(title: "Test", blocks: [
            .paragraph([
                .text("Some "),
                .strong("bold"),
                .text(" and "),
                .emphasis("italic"),
                .text(" and "),
                .code("code"),
                .text(" text."),
            ]),
        ])
        let md = ReaderDocumentMarkdownWriter.markdown(from: document)
        #expect(md.contains("**bold**"))
        #expect(md.contains("*italic*"))
        #expect(md.contains("`code`"))
    }

    @Test
    func markdownWriter_reconstructsBlockquotes() {
        let document = ReaderDocument(title: "Test", blocks: [
            .blockquote([.text("Quoted text")]),
        ])
        let md = ReaderDocumentMarkdownWriter.markdown(from: document)
        #expect(md.contains("> Quoted text"))
    }

    @Test
    func markdownWriter_reconstructsLists() {
        let document = ReaderDocument(title: "Test", blocks: [
            .list(ordered: false, items: [
                [.text("First")],
                [.text("Second")],
            ]),
        ])
        let md = ReaderDocumentMarkdownWriter.markdown(from: document)
        #expect(md.contains("- First"))
        #expect(md.contains("- Second"))
    }

    @Test
    func markdownWriter_reconstructsCodeBlocks() {
        let document = ReaderDocument(title: "Test", blocks: [
            .code(language: "swift", code: "let x = 42"),
        ])
        let md = ReaderDocumentMarkdownWriter.markdown(from: document)
        #expect(md.contains("```swift"))
        #expect(md.contains("let x = 42"))
        #expect(md.contains("```"))
    }

    @Test
    func markdownWriter_roundTrips() async throws {
        let source = """
        # My Article

        A paragraph with **bold** and *italic* text.

        > A blockquote

        - Item one
        - Item two

        ```python
        print("hello")
        ```

        ---
        """
        let result = try await TextIngestionClient.live.ingest(source, nil, nil, .markdown)
        let reconstructed = ReaderDocumentMarkdownWriter.markdown(from: result.document)

        // Re-parse the reconstructed markdown and verify blocks match
        let reparsed = try await TextIngestionClient.live.ingest(reconstructed, nil, nil, .markdown)
        #expect(reparsed.document.blocks.count == result.document.blocks.count)
    }
}
