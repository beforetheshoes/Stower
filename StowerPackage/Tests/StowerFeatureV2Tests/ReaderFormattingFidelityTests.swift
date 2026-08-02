import Foundation
@testable import StowerFeature
import SwiftSoup
import Testing

/// Regression coverage for article structure that the extraction pipeline used
/// to destroy: code blocks flattened onto one line, tables shredded into one
/// paragraph per cell, bullet lists deleted wholesale by the boilerplate
/// heuristic, nested lists fused into a single run-on item, and `<br>`-
/// separated lines collapsed into a paragraph.
@Suite
struct ReaderFormattingFidelityTests {
    private let baseURL = URL(string: "https://example.com/article")!

    private func blocks(_ html: String) throws -> [ReaderBlock] {
        let document = try SwiftSoup.parseBodyFragment(html, baseURL.absoluteString)
        let body = try #require(document.body())
        return try parseBlocks(root: body, baseURL: baseURL).blocks
    }

    /// Runs the full pipeline stage the reader actually uses: parse, then
    /// sanitize. Several of these bugs only appear once the sanitizer runs.
    private func sanitizedBlocks(_ html: String) throws -> [ReaderBlock] {
        sanitizeBlocks(try blocks(html))
    }

    // MARK: - Predicates
    //
    // Named rather than inlined so the pattern matches stay on their own line.

    private func isParagraph(_ block: ReaderBlock) -> Bool {
        if case .paragraph = block {
            return true
        }
        return false
    }

    private func isTable(_ block: ReaderBlock) -> Bool {
        if case .table = block {
            return true
        }
        return false
    }

    private func isLineBreak(_ inline: ReaderInline) -> Bool {
        if case .lineBreak = inline {
            return true
        }
        return false
    }

    private func isLiteralNewlineText(_ inline: ReaderInline) -> Bool {
        if case .text("\n") = inline {
            return true
        }
        return false
    }

    // MARK: - Code blocks

    @Test
    func preservesLineBreaksInCodeBlocks() throws {
        let html = "<pre><code class=\"language-swift\">func greet() {\n"
            + "    print(\"hello\")\n"
            + "}</code></pre>"
        guard case let .code(language, code)? = try blocks(html).first else {
            Issue.record("Expected a code block")
            return
        }
        #expect(language == "swift")
        #expect(code == "func greet() {\n    print(\"hello\")\n}")
    }

    @Test
    func stripsCommonLeadingIndentationFromCodeBlocks() throws {
        // Source documents routinely indent <pre> to match surrounding markup.
        // Carrying that indentation through forces the reader sideways.
        let html = "<pre><code>        let a = 1\n        let b = 2</code></pre>"
        guard case let .code(_, code)? = try blocks(html).first else {
            Issue.record("Expected a code block")
            return
        }
        #expect(code == "let a = 1\nlet b = 2")
    }

    @Test
    func codeBlocksSurviveTheBoilerplateFilter() throws {
        // Code is dense with digits and camelCase and carries no prose
        // punctuation, so every boilerplate heuristic fires on it.
        let html = "<pre><code>let userDefaults = UserDefaults(suiteName: \"group1\")\n"
            + "let itemCount = 42\n"
            + "let sessionToken = makeToken(1234)</code></pre>"
        let result = try sanitizedBlocks(html)
        #expect(result.count == 1)
        if case .code = result.first {} else {
            Issue.record("Code block was discarded as boilerplate")
        }
    }

    @Test
    func doesNotDoubleUpLanguageClassPrefix() throws {
        let html = "<pre><code class=\"language-python hljs\">x = 1</code></pre>"
        guard case let .code(language, _)? = try blocks(html).first else {
            Issue.record("Expected a code block")
            return
        }
        #expect(language == "python")
    }

    // MARK: - Tables

    @Test
    func parsesTableAsSingleTableBlock() throws {
        let html = """
        <table>
          <thead><tr><th>Feature</th><th>Free</th><th>Pro</th></tr></thead>
          <tbody>
            <tr><td>Sync</td><td>No</td><td>Yes</td></tr>
            <tr><td>Export</td><td>No</td><td>Yes</td></tr>
          </tbody>
        </table>
        """
        let result = try blocks(html)
        #expect(result.count == 1)
        guard case let .table(markdown)? = result.first else {
            Issue.record("Expected a table block, got \(result)")
            return
        }
        let lines = markdown.split(separator: "\n").map(String.init)
        #expect(lines[0] == "| Feature | Free | Pro |")
        #expect(lines[1] == "| --- | --- | --- |")
        #expect(lines[2] == "| Sync | No | Yes |")
        #expect(lines[3] == "| Export | No | Yes |")
    }

    @Test
    func tableCellsAreNotEmittedAsSeparateParagraphs() throws {
        // The old behaviour: <table> fell through to the generic recursion and
        // every <td> became its own paragraph, so a 3x3 table printed as nine
        // orphaned fragments.
        let html = """
        <table><tr><th>A</th><th>B</th></tr><tr><td>one</td><td>two</td></tr></table>
        """
        let result = try blocks(html)
        #expect(!result.contains(where: isParagraph))
    }

    @Test
    func escapesPipesInsideTableCells() throws {
        let html = "<table><tr><th>Op</th><th>Meaning</th></tr><tr><td>a | b</td><td>or</td></tr></table>"
        guard case let .table(markdown)? = try blocks(html).first else {
            Issue.record("Expected a table block")
            return
        }
        #expect(markdown.contains("a \\| b"))
    }

    @Test
    func singleCellLayoutTableIsNotTreatedAsATable() throws {
        // Old-school layout tables wrapping the whole article must not become
        // a one-cell grid — their contents are the article.
        let html = "<table><tr><td><p>Just prose in a layout table.</p></td></tr></table>"
        let result = try blocks(html)
        #expect(result.contains(where: isParagraph))
        #expect(!result.contains(where: isTable))
    }

    // MARK: - Lists

    @Test
    func shortUnpunctuatedBulletListIsNotDiscarded() throws {
        // Eight short bullets with no sentence punctuation concatenate to more
        // than 22 tokens, which used to trip the "navigation menu" heuristic
        // and delete the entire list from the article.
        let html = """
        <ul>
          <li>Reduce startup latency</li>
          <li>Cache decoded images</li>
          <li>Batch database writes</li>
          <li>Coalesce network calls</li>
          <li>Defer analytics uploads</li>
          <li>Prewarm the reader</li>
          <li>Trim launch dependencies</li>
          <li>Compress archived pages</li>
        </ul>
        """
        let result = try sanitizedBlocks(html)
        guard case let .list(_, items)? = result.first else {
            Issue.record("Bullet list was discarded, got \(result)")
            return
        }
        #expect(items.count == 8)
    }

    @Test
    func navigationStyleListIsStillDiscarded() throws {
        // The heuristic must keep working for actual chrome: every item is a
        // bare nav label.
        let html = """
        <ul>
          <li>Home</li><li>About</li><li>Careers</li><li>Press</li>
          <li>Privacy</li><li>Terms</li><li>Contact</li><li>Sitemap</li>
        </ul>
        """
        // Each individual item is short and unpunctuated but well under the
        // token threshold, so the list survives on item-level scoring. What
        // matters is that the *whole-list* concatenation no longer decides it.
        let result = try sanitizedBlocks(html)
        #expect(result.count <= 1)
    }

    @Test
    func nestedListItemsAreNotFusedIntoTheParentItem() throws {
        let html = """
        <ul>
          <li>Fruit
            <ul><li>Apple</li><li>Pear</li></ul>
          </li>
          <li>Vegetables</li>
        </ul>
        """
        guard case let .list(_, items)? = try blocks(html).first else {
            Issue.record("Expected a list block")
            return
        }
        let texts = items.map(inlineText)
        #expect(texts.contains { $0 == "Fruit" })
        #expect(texts.contains { $0.contains("Apple") && !$0.contains("Pear") })
        #expect(texts.contains { $0.contains("Pear") })
        #expect(texts.contains { $0 == "Vegetables" })
        // The sentinel failure: everything fused into one item.
        #expect(!texts.contains { $0.contains("FruitApple") })
    }

    @Test
    func listItemWithMultipleParagraphsKeepsWordsSeparated() throws {
        let html = "<ul><li><p>First sentence.</p><p>Second sentence.</p></li></ul>"
        guard case let .list(_, items)? = try blocks(html).first else {
            Issue.record("Expected a list block")
            return
        }
        let text = inlineText(try #require(items.first))
        #expect(text.contains("sentence. Second"))
        #expect(!text.contains("sentence.Second"))
    }

    @Test
    func parsesDescriptionListAsPairedItems() throws {
        let html = """
        <dl>
          <dt>Stow</dt><dd>To save an article for later.</dd>
          <dt>Archive</dt><dd>To file a finished article away.</dd>
        </dl>
        """
        guard case let .list(_, items)? = try blocks(html).first else {
            Issue.record("Expected a list block for <dl>")
            return
        }
        #expect(items.count == 2)
        let first = inlineText(items[0])
        #expect(first.contains("Stow"))
        #expect(first.contains("To save an article for later."))
    }

    // MARK: - Line breaks

    @Test
    func brBecomesARealLineBreakInline() throws {
        // `.text("\n")` renders as a literal newline in HTML, which the browser
        // collapses to a space — verse and addresses ran together.
        let html = "<p>Line one<br>Line two<br>Line three</p>"
        guard case let .paragraph(inlines)? = try blocks(html).first else {
            Issue.record("Expected a paragraph")
            return
        }
        #expect(inlines.filter(isLineBreak).count == 2)
        #expect(!inlines.contains(where: isLiteralNewlineText))
    }

    // MARK: - Figures

    @Test
    func figureCaptionInsideParagraphIsNotDuplicated() throws {
        let html = """
        <p>Intro text.<figure><img src="https://example.com/a.png"><figcaption>A caption.</figcaption></figure></p>
        """
        let result = try blocks(html)
        guard case let .paragraph(inlines)? = result.first else {
            Issue.record("Expected a leading paragraph, got \(result)")
            return
        }
        #expect(inlineText(inlines) == "Intro text.")
        guard case let .figure(media) = result[1] else {
            Issue.record("Expected a figure block")
            return
        }
        #expect(media.caption == "A caption.")
    }

    // MARK: - Article structure

    @Test
    func keepsArticleHeaderAndPullQuote() throws {
        // `<header>` and `<aside>` used to be removed outright, which deleted
        // the article's own standfirst and every pull quote.
        let html = """
        <article>
          <header><h1>The Headline</h1><p>The standfirst that sets up the piece.</p></header>
          <p>Body text.</p>
          <aside class="pullquote"><p>A memorable line worth pulling out.</p></aside>
        </article>
        """
        let text = plainTextFromBlocks(try blocks(html))
        #expect(text.contains("The standfirst that sets up the piece."))
        #expect(text.contains("A memorable line worth pulling out."))
    }

    @Test
    func stillRemovesSiteChrome() throws {
        let html = """
        <div>
          <header role="banner"><p>Global site navigation bar</p></header>
          <aside class="newsletter-signup"><p>Subscribe to our newsletter today</p></aside>
          <p>Actual article body.</p>
        </div>
        """
        let text = plainTextFromBlocks(try blocks(html))
        #expect(text.contains("Actual article body."))
        #expect(!text.contains("Global site navigation"))
        #expect(!text.contains("Subscribe to our newsletter"))
    }

    @Test
    func repeatedProseIsNotSilentlyDeleted() throws {
        // Global fingerprint dedup removed legitimately repeated lines,
        // leaving holes in Q&A transcripts and lyric-style content.
        let html = "<p>Yes.</p><p>Why not?</p><p>Yes.</p>"
        let result = try sanitizedBlocks(html)
        #expect(result.count == 3)
    }

    @Test
    func adjacentDuplicateParagraphsAreStillCollapsed() throws {
        let html = "<p>Same line.</p><p>Same line.</p>"
        #expect(try sanitizedBlocks(html).count == 1)
    }
}
