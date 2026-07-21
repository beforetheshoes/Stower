import Foundation
@testable import StowerFeature
import Testing

@Suite
struct RenderedArticleExtractorTests {
    @Test
    func preservesSemanticArticleStructureAndSanitizesChrome() throws {
        let html = """
            <!doctype html><html lang="en"><head>
              <title>Document fallback</title>
              <meta property="og:site_name" content="Fixture News">
              <script type="application/ld+json">
                {"@type":"NewsArticle","headline":"Reliable title","description":"The deck",
                 "author":{"name":"Ada Author"},"datePublished":"2026-07-20T12:00:00Z",
                 "image":"https://example.com/hero.jpg"}
              </script>
            </head><body>
              <nav>Navigation</nav><div class="advertisement">Buy this</div>
              <article>
                <h1>Source heading</h1><p class="deck">The deck</p>
                <p>First paragraph with enough meaningful text for article extraction and selection.</p>
                <figure><picture><source srcset="wide.webp"><img src="hero.jpg" onerror="steal()"></picture><figcaption>Caption</figcaption></figure>
                <ol><li>Outer<ul><li>Nested</li></ul></li></ol>
                <blockquote>A quotation</blockquote><pre><code>let value = 1</code></pre>
                <table><thead><tr><th>Head</th></tr></thead><tbody><tr><td>Cell</td></tr></tbody></table>
                <dl><dt>Term</dt><dd>Definition</dd></dl>
                <details><summary>More</summary><p>Hidden only until opened, not removed.</p></details>
                <p>Equation <math><mi>x</mi><mo>=</mo><mn>1</mn></math></p>
                <svg viewBox="0 0 10 10" onclick="evil()"><script>evil()</script><circle cx="5" cy="5" r="4"/></svg>
                <video poster="poster.jpg"><source src="clip.mp4"></video>
                <iframe src="https://player.example/video"></iframe>
                <p id="footnote-1">Footnote content</p>
                <script>alert(1)</script><form><input value="tracking"></form>
              </article>
              <section class="comments">Comment noise</section>
            </body></html>
            """

        let result = try RenderedArticleExtractor.extract(
            renderedHTML: html,
            sourceURL: URL(string: "https://example.com/story")!
        )

        #expect(result.title == "Reliable title")
        #expect(result.author == "Ada Author")
        #expect(result.siteName == "Fixture News")
        #expect(result.heroImageURL == "https://example.com/hero.jpg")
        #expect(result.readerHTML.contains("Content-Security-Policy"))
        #expect(result.readerHTML.contains("<figure"))
        #expect(result.readerHTML.contains("<figcaption"))
        #expect(result.readerHTML.contains("Caption"))
        #expect(result.readerHTML.contains("<table"))
        #expect(result.readerHTML.contains("<dl"))
        #expect(result.readerHTML.contains("<details"))
        #expect(result.readerHTML.contains("<math"))
        #expect(result.readerHTML.contains("<svg"))
        #expect(result.readerHTML.contains("Open embedded content"))
        #expect(result.readerHTML.contains("data-block-index"))
        #expect(!result.readerHTML.contains("Navigation"))
        #expect(!result.readerHTML.contains("Buy this"))
        #expect(!result.readerHTML.contains("Comment noise"))
        #expect(!result.readerHTML.contains("<form"))
        #expect(!result.readerHTML.contains("<script"))
        #expect(!result.readerHTML.contains("onclick="))
        #expect(!result.readerHTML.contains("onerror="))

        let paragraph = try #require(result.readerHTML.range(of: "First paragraph"))
        let figure = try #require(result.readerHTML.range(of: "<figure"))
        let list = try #require(result.readerHTML.range(of: "<ol"))
        #expect(paragraph.lowerBound < figure.lowerBound)
        #expect(figure.lowerBound < list.lowerBound)
    }

    @Test
    func metadataFallsBackToArticleHeadingThenHostname() throws {
        let heading = try RenderedArticleExtractor.extract(
            renderedHTML: "<article><h1>Heading title</h1><p>This is a sufficiently long article body for extraction to succeed without metadata.</p></article>",
            sourceURL: URL(string: "https://fallback.example/post")!
        )
        #expect(heading.title == "Heading title")

        let hostname = try RenderedArticleExtractor.extract(
            renderedHTML: "<article><p>This is a sufficiently long article body for extraction to succeed without any title element.</p></article>",
            sourceURL: URL(string: "https://fallback.example/post")!
        )
        #expect(hostname.title == "fallback.example")
    }

    @Test
    func semanticRootWinsWhenItContainsReadabilityText() throws {
        let readability = MozillaReadabilityResult(
            title: "Readability title",
            byline: "Reader Author",
            language: "en",
            content: "<div><p>Processed fallback</p></div>",
            textContent: "Important preserved sentence with original semantic structure and enough overlap to reconcile.",
            excerpt: nil,
            siteName: nil,
            publishedTime: nil
        )
        let result = try RenderedArticleExtractor.extract(
            renderedHTML: """
                <main><article><p>Important preserved sentence with original semantic structure and enough overlap to reconcile.</p><details><summary>Original detail</summary><p>Nested value</p></details></article></main>
                """,
            sourceURL: URL(string: "https://example.com")!,
            readability: readability
        )
        #expect(result.title == "Readability title")
        #expect(result.readerHTML.contains("Original detail"))
        #expect(!result.readerHTML.contains("Processed fallback"))
    }

    @Test
    func removesUnsafeSchemesAndTrackingPixels() throws {
        let result = try RenderedArticleExtractor.extract(
            renderedHTML: """
                <article><h1>Security</h1><p>This body is long enough to keep during sanitizer testing of unsafe links.</p>
                <a href="javascript:alert(1)">Unsafe</a><img width="1" height="1" src="https://tracker.example/pixel.gif">
                <svg><foreignObject><p>HTML escape</p></foreignObject></svg></article>
                """,
            sourceURL: URL(string: "https://example.com")!
        )
        #expect(!result.readerHTML.contains("javascript:"))
        #expect(!result.readerHTML.contains("tracker.example"))
        #expect(!result.readerHTML.contains("foreignObject"))
    }
}
