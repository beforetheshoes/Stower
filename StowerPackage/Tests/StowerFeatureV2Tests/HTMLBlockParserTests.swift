import Foundation
@testable import StowerFeature
import SwiftSoup
import Testing

@Suite
struct HTMLBlockParserTests {
    // Parse an HTML fragment, pull the first paragraph out of the body, and
    // return its raw `[ReaderInline]` array. Inspecting these segments
    // directly is the only way to verify that boundary whitespace survives
    // parsing — the higher-level `plainTextFromBlocks` helper always joins
    // segments with a space separator, which would mask the bug.
    private func parseParagraphInlines(_ html: String) throws -> [ReaderInline] {
        let document = try SwiftSoup.parseBodyFragment(html)
        let body = try #require(document.body())
        let paragraph = try #require(try body.select("p").first())
        return try parseInlines(paragraph)
    }

    // Concatenate the raw text content of each inline segment WITHOUT
    // inserting any separator. This mirrors what `renderInlines()` in
    // `ReaderDocumentHTMLBuilder` does when building the WKWebView HTML,
    // so it reflects what the user actually sees on screen.
    private func concatenatedRawText(_ inlines: [ReaderInline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let value):
                return value
            case .lineBreak:
                return "\n"
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

    @Test
    func preservesSpaceAroundLink() throws {
        let inlines = try parseParagraphInlines("<p>word <a href=\"https://example.com\">link</a> text</p>")
        #expect(concatenatedRawText(inlines) == "word link text")
    }

    @Test
    func preservesSpaceAroundStrong() throws {
        let inlines = try parseParagraphInlines("<p>a <strong>bold</strong> b</p>")
        #expect(concatenatedRawText(inlines) == "a bold b")
    }

    @Test
    func doesNotFabricateSpaceWhenNoneExisted() throws {
        // No whitespace around the <strong> element — the concatenated
        // output must remain contiguous.
        let inlines = try parseParagraphInlines("<p>a<strong>bold</strong>b</p>")
        #expect(concatenatedRawText(inlines) == "aboldb")
    }

    @Test
    func keepsPunctuationAdjacentToInlineFormatting() throws {
        let inlines = try parseParagraphInlines("<p>word <em>em</em>, next</p>")
        #expect(concatenatedRawText(inlines) == "word em, next")
    }

    @Test
    func preservesSpacesBetweenAdjacentLinks() throws {
        let inlines = try parseParagraphInlines(
            "<p>one <a href=\"https://a.example\">two</a> <a href=\"https://b.example\">three</a> four</p>"
        )
        #expect(concatenatedRawText(inlines) == "one two three four")
    }

    @Test
    func trimsLeadingAndTrailingWhitespaceOnParagraph() throws {
        let inlines = try parseParagraphInlines("<p>  leading and trailing  </p>")
        #expect(concatenatedRawText(inlines) == "leading and trailing")
    }

    @Test
    func preservesSpacingAcrossNestedUnknownSpan() throws {
        let inlines = try parseParagraphInlines(
            "<p>x <span>y <a href=\"https://z.example\">z</a> w</span> v</p>"
        )
        #expect(concatenatedRawText(inlines) == "x y z w v")
    }

    @Test
    func preservesSpaceAroundInlineCode() throws {
        let inlines = try parseParagraphInlines("<p>use <code>parseInlines</code> to build segments</p>")
        #expect(concatenatedRawText(inlines) == "use parseInlines to build segments")
    }

    @Test
    func preservesSpaceAroundMixedFormatting() throws {
        let inlines = try parseParagraphInlines(
            "<p>A <strong>bold</strong> <em>italic</em> and <a href=\"https://x.example\">link</a> together.</p>"
        )
        #expect(concatenatedRawText(inlines) == "A bold italic and link together.")
    }

    @Test
    func preservesTrailingSpaceInsideAnchorTag() throws {
        // Real-world case: the source HTML has the space INSIDE the <a>
        // tag, so SwiftSoup's default `Element.text()` (which trims) would
        // drop it and the link would render smooshed against the following
        // word. The parser has to read the anchor's text with
        // `trimAndNormaliseWhitespace: false` and emit a boundary `.text(" ")`
        // segment when trailing whitespace is detected.
        let inlines = try parseParagraphInlines(
            "<p>users <a href=\"https://example.com\">spammed Venmo requests </a>until the end</p>"
        )
        #expect(concatenatedRawText(inlines) == "users spammed Venmo requests until the end")
    }

    @Test
    func preservesLeadingSpaceInsideAnchorTag() throws {
        // Mirror case: leading whitespace inside the anchor.
        let inlines = try parseParagraphInlines(
            "<p>users<a href=\"https://example.com\"> spammed Venmo requests</a> until the end</p>"
        )
        #expect(concatenatedRawText(inlines) == "users spammed Venmo requests until the end")
    }

    @Test
    func preservesSpaceWhenWrapperSpansAreInterleavedWithLinks() throws {
        // Real-world shape pulled from an EFF article: text runs are
        // wrapped in <span> elements, with links interspersed and no
        // whitespace inside the anchor. The leading space on the trailing
        // <span> is the only thing separating the link from the following
        // word, and it must survive parsing through the <span> wrapper.
        let html = """
        <p><span>other cases, attackers have</span> <a href="https://example.com"><span>spammed Venmo requests</span></a><span> until the user accidentally accepted.</span></p>
        """
        let inlines = try parseParagraphInlines(html)
        #expect(concatenatedRawText(inlines) == "other cases, attackers have spammed Venmo requests until the user accidentally accepted.")
    }

    @Test
    func preservesSpaceBetweenSpanAndFollowingLink() throws {
        // Mirror of the EFF shape: trailing span ends a sentence, single
        // TextNode space separates it from an anchor, then another span
        // continues with a period — no leading whitespace on the
        // continuation span.
        let html = """
        <p><span>prime target for</span> <a href="#phishing">potential phishing attempts</a><span>. It's important.</span></p>
        """
        let inlines = try parseParagraphInlines(html)
        #expect(concatenatedRawText(inlines) == "prime target for potential phishing attempts. It's important.")
    }

    @Test
    func liveExtractionAgainstRealEFFArticleFile() async throws {
        // Hermetic to this machine, but invaluable as a diagnostic: runs
        // the live extraction pipeline against the ACTUAL downloaded EFF
        // HTML file and verifies the user-visible "phishing" list item
        // comes out with correct spacing. Skip silently if the file isn't
        // present.
        let path = "/tmp/eff_article.html"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let html = try String(contentsOfFile: path, encoding: .utf8)

        let result = try await ExtractionPipelineClient.live.extract(
            html,
            URL(string: "https://www.eff.org/deeplinks/2020/03/keeping-each-other-safe-when-virtually-organizing-mutual-aid")!
        )

        // Search every block/list-item/paragraph for the known-broken text.
        func textOf(_ inlines: [ReaderInline]) -> String {
            inlines.map { inline -> String in
                switch inline {
                case .text(let value):
                    return value
                case .lineBreak:
                    return "\n"
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

        var foundPhishing: String?
        for block in result.document.blocks {
            switch block {
            case .paragraph(let inlines), .blockquote(let inlines), .heading(_, let inlines), .callout(_, let inlines):
                let t = textOf(inlines)
                if t.contains("phishing attempts") { foundPhishing = t }
            case .list(_, let items):
                for item in items {
                    let t = textOf(item)
                    if t.contains("phishing attempts") { foundPhishing = t }
                }
            default:
                break
            }
        }

        let text = try #require(foundPhishing, "Could not find 'phishing attempts' in extracted blocks")
        // The smooshed failure mode looks like "...attemptsrelating...".
        #expect(!text.contains("attemptsrelating"), "Expected boundary space around link; got: \(text)")
        #expect(text.contains("phishing attempts relating") || text.contains("phishing attempts "))

        // Guard against silent regression into `.webView` mode for this
        // shape of article — that would bypass the parser entirely.
        #expect(result.renderFormat == .structuredV1)

        // FULL round trip: encode → decode → sanitizeLoadedBlocks → render HTML.
        // This mirrors exactly what the running app does when loading an
        // article back from the database and showing it in the reader.
        let data = try JSONEncoder().encode(result.document)
        var decoded = try JSONDecoder().decode(ReaderDocument.self, from: data)
        decoded.blocks = sanitizeLoadedBlocks(decoded.blocks)

        var foundAfterSanitize: String?
        for block in decoded.blocks {
            switch block {
            case .paragraph(let inlines), .blockquote(let inlines), .heading(_, let inlines), .callout(_, let inlines):
                let t = textOf(inlines)
                if t.contains("phishing attempts") { foundAfterSanitize = t }
            case .list(_, let items):
                for item in items {
                    let t = textOf(item)
                    if t.contains("phishing attempts") { foundAfterSanitize = t }
                }
            default:
                break
            }
        }
        let afterSanitize = try #require(foundAfterSanitize)
        #expect(!afterSanitize.contains("attemptsrelating"), "sanitizeLoadedBlocks ate the boundary space: \(afterSanitize)")

        // FINAL: run buildReaderHTML and grep the generated HTML. This is
        // exactly what WKWebView loads.
        let item = SavedItem(
            title: "Keeping Each Other Safe",
            content: "",
            sourceURL: "https://example.com/mutual-aid",
            renderFormat: .structuredV1
        )
        let rendered = ReaderDocumentHTMLBuilder.buildReaderHTML(
            item: item,
            document: decoded,
            appearance: ReaderAppearanceSettings()
        )
        #expect(!rendered.contains("attemptsrelating"), "buildReaderHTML ate the boundary space")
        #expect(rendered.contains("phishing attempts</a>") || rendered.contains("phishing attempts </a>"))
    }

    @Test
    func liveExtractionPreservesLinkSpacingInEFFArticleShape() async throws {
        // Run the REAL live extraction pipeline (chooseRoot → parseBlocks →
        // sanitizeBlocks) against a minimal HTML document whose list item
        // matches the exact EFF article shape the user is seeing broken in
        // the reader. If this passes and the reader still renders
        // smooshed text, the bug is downstream of extraction (sanitizer,
        // HTML builder, or stale cache).
        let html = """
        <!doctype html><html><head><title>Keeping Each Other Safe</title></head>
        <body><article><div class="article-content">
        <p>Some additional considerations for people participating in mutual aid efforts are:</p>
        <ul>
        <li><span>Know your risks: can you communicate these concerns with the organizers?</span></li>
        <li><span>Be wary of </span><span><a href=\"#phishing\">potential phishing attempts</a>\u{00A0}</span><span>relating to the information provided.</span></li>
        </ul>
        </div></article></body></html>
        """
        let result = try await ExtractionPipelineClient.live.extract(html, URL(string: "https://example.com/mutual-aid")!)

        // Walk the blocks to find the "Be wary of" list item.
        var foundText: String?
        for block in result.document.blocks {
            guard case .list(_, let items) = block else { continue }
            for item in items {
                let text = item.map { inline -> String in
                    switch inline {
                    case .text(let value):
                        return value
                    case .lineBreak:
                        return "\n"
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
                if text.contains("phishing") {
                    foundText = text
                    break
                }
            }
        }

        let text = try #require(foundText)
        #expect(text == "Be wary of potential phishing attempts relating to the information provided.")
    }

    @Test
    func preservesNbspAsBoundarySpaceInsideNestedSpan() throws {
        // Verbatim from an EFF mutual-aid article list item: a non-breaking
        // space (U+00A0) sits between the closing </a> and the closing
        // </span> of the wrapping inner span, with NO whitespace on the
        // following sibling span. The parser must treat the NBSP as a
        // boundary space so the rendered text reads "...phishing attempts
        // relating to..." rather than "...attemptsrelating to...".
        //
        // Because `<li>` is the containing block, we have to parse via a
        // full list and pull the inlines out of the resulting block.
        let html = """
        <ul><li><span>Be wary of </span><span><a href=\"#phishing\">potential phishing attempts</a>\u{00A0}</span><span>relating to the information provided.</span></li></ul>
        """
        let document = try SwiftSoup.parseBodyFragment(html)
        let body = try #require(document.body())
        let parsed = try parseBlocks(root: body, baseURL: URL(string: "https://example.com")!)
        guard case .list(_, let items) = parsed.blocks.first else {
            Issue.record("Expected a list block")
            return
        }
        let inlines = try #require(items.first)
        #expect(concatenatedRawText(inlines) == "Be wary of potential phishing attempts relating to the information provided.")
    }

    @Test
    func preservesTrailingSpaceInsideStrongTag() throws {
        let inlines = try parseParagraphInlines("<p>very <strong>important </strong>notice</p>")
        #expect(concatenatedRawText(inlines) == "very important notice")
    }

    @Test
    func collapsesInteriorWhitespaceRuns() throws {
        // Multiple whitespace characters (including a newline) between a
        // text node and a link should collapse to a single space.
        let inlines = try parseParagraphInlines(
            "<p>word  \n  <a href=\"https://example.com\">link</a>  tail</p>"
        )
        #expect(concatenatedRawText(inlines) == "word link tail")
    }

    @Test
    func linkSurroundedByTextYieldsExactlyThreeSegments() throws {
        // Regression guard: the sentinel shape of the bug is that boundary
        // spaces disappear, leaving `[.text("word"), .link("link"), .text("text")]`
        // which then concatenates as "wordlinktext". After the fix we
        // expect the text segments to carry the boundary spaces.
        let inlines = try parseParagraphInlines(
            "<p>word <a href=\"https://example.com\">link</a> text</p>"
        )
        #expect(inlines.count == 3)
        guard case .text(let leading) = inlines[0] else {
            Issue.record("Expected leading text segment")
            return
        }
        guard case .link(let label, _) = inlines[1] else {
            Issue.record("Expected link segment")
            return
        }
        guard case .text(let trailing) = inlines[2] else {
            Issue.record("Expected trailing text segment")
            return
        }
        #expect(leading.hasSuffix(" "))
        #expect(label == "link")
        #expect(trailing.hasPrefix(" "))
    }
}
