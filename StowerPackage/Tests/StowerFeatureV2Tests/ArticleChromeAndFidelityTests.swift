import Foundation
@testable import StowerFeature
import SwiftSoup
import Testing

/// Regression coverage for the things that made a real Substack essay
/// (oneusefulthing.org) read badly: it was classified as "interactive" and so
/// opened as a shrunken desktop page, its title appeared twice, and the
/// platform's like/restack furniture ran on past the end of the article.
@Suite
struct ArticleChromeAndFidelityTests {
    private let sourceURL = URL(string: "https://www.example.com/p/an-essay")!

    private func extract(_ html: String) throws -> RenderedArticleExtraction {
        try RenderedArticleExtractor.extract(renderedHTML: html, sourceURL: sourceURL)
    }

    private func page(body: String, head: String = "") -> String {
        """
        <!doctype html><html><head><meta property="og:title" content="An opinionated guide">\(head)</head>
        <body>\(body)</body></html>
        """
    }

    /// Enough prose to clear the extractor's 40-character minimum.
    private let filler = """
        <p>Every few months I write a guide for people who want to use these tools \
        to actually do something useful with their working day.</p>
        <p>The landscape keeps shifting, so any guide is out of date the moment it \
        is published, which is worth keeping in mind.</p>
        """

    // MARK: - Interactive classification

    @Test
    func anEssayWithEmbeddedVideoIsNotTreatedAsInteractive() throws {
        // `.webView` articles get no reader typography and are laid out at
        // capture width, so on a phone they arrive as a shrunken desktop page.
        // An essay with a video in it is still an essay.
        let html = page(body: "<article>\(filler)<video src=\"https://cdn.example.com/a.mp4\"></video></article>")
        #expect(try extract(html).isInteractive == false)
    }

    @Test
    func anEssayWithIframeEmbedsIsNotTreatedAsInteractive() throws {
        // Two iframes in the rendered DOM were enough to route a plain essay
        // to the raw-archive renderer.
        let html = page(body: """
            <article>\(filler)
            <iframe src="https://player.example.com/1"></iframe>
            <iframe src="https://player.example.com/2"></iframe>
            </article>
            """)
        #expect(try extract(html).isInteractive == false)
    }

    @Test
    func audioPlayerDoesNotForceTheArchiveRenderer() throws {
        let html = page(body: "<article>\(filler)<audio src=\"https://cdn.example.com/a.mp3\"></audio></article>")
        #expect(try extract(html).isInteractive == false)
    }

    @Test
    func canvasStillCountsAsInteractive() throws {
        let html = page(body: "<article>\(filler)<canvas id=\"sim\"></canvas></article>")
        #expect(try extract(html).isInteractive == true)
    }

    @Test
    func animatedSVGStillCountsAsInteractive() throws {
        let html = page(body: "<article>\(filler)<svg><animate attributeName=\"x\"/></svg></article>")
        #expect(try extract(html).isInteractive == true)
    }

    @Test
    func chartingLibraryStillCountsAsInteractive() throws {
        let html = page(body: "<article>\(filler)<script src=\"https://cdn.example.com/highcharts.js\"></script></article>")
        #expect(try extract(html).isInteractive == true)
    }

    @Test
    func aGenericPointerListenerNoLongerCountsAsInteractive() throws {
        // Practically every site with a carousel ships this.
        let html = page(body: """
            <article>\(filler)<script>el.addEventListener('pointerdown', fn)</script></article>
            """)
        #expect(try extract(html).isInteractive == false)
    }

    // MARK: - Platform chrome

    @Test
    func stripsThePostHeaderBlock() throws {
        // The reader renders its own title/byline/date header, so the source's
        // header block printed all of it a second time.
        let html = page(body: """
            <article>
              <div role="region" aria-label="Post header" class="post-header">
                <h1 class="post-title">An opinionated guide</h1>
                <h3 class="subtitle">The Summer Edition</h3>
                <div>Ethan Mollick</div><time>Jul 23, 2026</time>
              </div>
              \(filler)
            </article>
            """)
        let text = try extract(html).plainText
        #expect(!text.contains("The Summer Edition"))
        #expect(!text.contains("Ethan Mollick"))
        #expect(text.contains("Every few months"))
    }

    @Test
    func stripsLikeAndRestackFurnitureAtTheEnd() throws {
        let html = page(body: """
            <article>
              \(filler)
              <div class="post-ufi">
                <div class="facepile"><img src="https://cdn.example.com/a1.png"><img src="https://cdn.example.com/a2.png"></div>
                <span>965 Likes</span><span>64 Restacks</span>
              </div>
              <p class="button-wrapper"><a href="https://example.com/book">Pre-Order my Book</a></p>
            </article>
            """)
        let text = try extract(html).plainText
        #expect(!text.contains("965 Likes"))
        #expect(!text.contains("64 Restacks"))
        #expect(!text.contains("Pre-Order my Book"))
        #expect(text.contains("Every few months"))
    }

    @Test
    func keepsBodyImagesThatCarryARestackAffordance() throws {
        // Substack marks every body image `can-restack`. A `[class*=restack]`
        // removal pattern deleted all nine images from a real article.
        let html = page(body: """
            <article>
              \(filler)
              <div class="captioned-image-container">
                <a class="image-link image2 is-viewable-img can-restack">
                  <img src="https://cdn.example.com/figure-one.png" alt="A chart">
                </a>
              </div>
            </article>
            """)
        let readerHTML = try extract(html).readerHTML
        #expect(readerHTML.contains("figure-one.png"))
    }

    @Test
    func stillRemovesTheRestackControlItself() throws {
        let html = page(body: """
            <article>\(filler)<button class="restack-button">Restack this</button></article>
            """)
        #expect(!(try extract(html).plainText.contains("Restack this")))
    }

    @Test
    func doesNotRemoveBodyWrappersThatMerelyContainAChromeWord() throws {
        // Substring class matching is dangerous: `paywall-content` and
        // `story-headline-and-body` are body wrappers, not chrome.
        let html = page(body: """
            <article>
              <div class="paywall-content"><div class="story-headline-and-body">\(filler)</div></div>
            </article>
            """)
        let text = try extract(html).plainText
        #expect(text.contains("Every few months"))
        #expect(text.contains("The landscape keeps shifting"))
    }

    // MARK: - Duplicate title

    @Test
    func dropsALeadingHeadingThatRepeatsTheTitle() {
        let blocks: [ReaderBlock] = [
            .heading(level: 1, inlines: [.text("An Opinionated Guide!")]),
            .paragraph([.text("Body text goes here.")]),
        ]
        let result = removeLeadingTitleRepeat(blocks, title: "An opinionated guide")
        #expect(result.count == 1)
        if case .paragraph = result.first {} else {
            Issue.record("Expected the body paragraph to survive, got \(result)")
        }
    }

    @Test
    func keepsALeadingHeadingThatIsNotTheTitle() {
        let blocks: [ReaderBlock] = [
            .heading(level: 2, inlines: [.text("Introduction")]),
            .paragraph([.text("Body text goes here.")]),
        ]
        #expect(removeLeadingTitleRepeat(blocks, title: "An opinionated guide").count == 2)
    }

    @Test
    func keepsALaterSectionHeadingThatEchoesTheTitle() {
        // Only the leading heading is a duplicate; a section further down that
        // happens to match is real content.
        let blocks: [ReaderBlock] = [
            .paragraph([.text("An introductory paragraph before any heading.")]),
            .heading(level: 2, inlines: [.text("An opinionated guide")]),
        ]
        #expect(removeLeadingTitleRepeat(blocks, title: "An opinionated guide").count == 2)
    }

    @Test
    func looksPastAHeroFigureToFindTheHeading() {
        let media = MediaDescriptor(kind: .image, sourceURL: "https://cdn.example.com/hero.png")
        let blocks: [ReaderBlock] = [
            .figure(media: media),
            .heading(level: 1, inlines: [.text("An opinionated guide")]),
            .paragraph([.text("Body text goes here.")]),
        ]
        let result = removeLeadingTitleRepeat(blocks, title: "An opinionated guide")
        #expect(result.count == 2)
        if case .figure = result.first {} else {
            Issue.record("The hero figure should be kept")
        }
    }

    @Test
    func titleComparisonIgnoresPunctuationAndSmartQuotes() {
        let blocks: [ReaderBlock] = [
            .heading(level: 1, inlines: [.text("Don\u{2019}t Panic \u{2014} A Guide")]),
            .paragraph([.text("Body.")]),
        ]
        #expect(removeLeadingTitleRepeat(blocks, title: "Don't Panic - a guide").count == 1)
    }

    @Test
    func emptyTitleLeavesBlocksAlone() {
        let blocks: [ReaderBlock] = [.heading(level: 1, inlines: [.text("Something")])]
        #expect(removeLeadingTitleRepeat(blocks, title: "").count == 1)
    }

    // MARK: - Header rendering

    @Test
    func headerShowsAHumanDateNotARawTimestamp() throws {
        let html = page(
            body: "<article>\(filler)</article>",
            head: """
            <meta property="article:published_time" content="2026-07-23T14:05:24-04:00">
            <meta name="author" content="Ethan Mollick">
            """
        )
        let readerHTML = try extract(html).readerHTML
        // The machine-readable value stays in the attribute...
        #expect(readerHTML.contains("datetime=\"2026-07-23T14:05:24-04:00\""))
        // ...but the visible text is a formatted date.
        #expect(!readerHTML.contains(">2026-07-23T14:05:24-04:00<"))
        #expect(readerHTML.contains("Jul 23, 2026"))
    }

    @Test
    func headerSeparatesBylineFromDate() throws {
        let html = page(
            body: "<article>\(filler)</article>",
            head: """
            <meta property="article:published_time" content="2026-07-23T14:05:24-04:00">
            <meta name="author" content="Ethan Mollick">
            """
        )
        let readerHTML = try extract(html).readerHTML
        #expect(readerHTML.contains("&middot;"))
        #expect(!readerHTML.contains("Ethan Mollick</span> <time"))
    }
}
