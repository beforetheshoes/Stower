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

        let result = try await TextIngestionClient.live.ingest(source, nil, .markdown)

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
        let result = try await TextIngestionClient.live.ingest("Body text only", "Meeting Notes", .markdown)

        #expect(result.title == "Meeting Notes")
    }

    @Test
    func plainTextFallsBackToSharedNoteWhenNoTitleHintExists() async throws {
        let result = try await TextIngestionClient.live.ingest("Just plain text", nil, .plainText)

        #expect(result.title == "Shared Note")
        #expect(result.renderFormat == .plainText)
        #expect(result.document.blocks == [.paragraph([.text("Just plain text")])])
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
            .auto
        )

        #expect(result.renderFormat == .plainText)
        #expect(result.title == "Shared Note")
    }

    @Test
    func unsupportedNestedMarkdown_degradesToReadableText() async throws {
        let result = try await TextIngestionClient.live.ingest(
            """
            - Parent
              - Child
            """,
            nil,
            .markdown
        )

        #expect(!result.document.blocks.isEmpty)
        #expect(result.plainText.contains("Parent"))
        #expect(result.plainText.contains("Child"))
    }
}
