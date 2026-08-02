import Foundation
@testable import StowerFeature
import SwiftSoup
import Testing

/// Regression coverage for a How-To Geek article that opened with an author
/// biography and site furniture, then ran a gallery as a bulleted list of
/// photo credits — twice, once large and once small — and finally dumped an
/// eight-question quiz including every answer's "correct" *and* "incorrect"
/// explanation into the middle of the piece.
@Suite
struct ArticleWidgetAndGalleryTests {
    private let sourceURL = URL(string: "https://www.example.com/how-to-do-a-thing/")!

    private func extract(_ html: String) throws -> RenderedArticleExtraction {
        try RenderedArticleExtractor.extract(renderedHTML: html, sourceURL: sourceURL)
    }

    private func page(_ body: String) -> String {
        """
        <!doctype html><html><head><meta property="og:title" content="How to do a thing"></head>
        <body>\(body)</body></html>
        """
    }

    private let filler = """
        <p>Setting this up looks harder than it is, and the whole thing takes \
        about five minutes from start to finish.</p>
        <p>The steps below walk through it in order, with a screenshot for each \
        stage so nothing is ambiguous.</p>
        """

    private func blocks(_ html: String) throws -> [ReaderBlock] {
        let document = try SwiftSoup.parseBodyFragment(html, sourceURL.absoluteString)
        let body = try #require(document.body())
        return try parseBlocks(root: body, baseURL: sourceURL).blocks
    }

    // MARK: - Predicates
    //
    // Named so the pattern matches stay on their own line.

    private func isList(_ block: ReaderBlock) -> Bool {
        if case .list = block {
            return true
        }
        return false
    }

    private func isFigure(_ block: ReaderBlock) -> Bool {
        if case .figure = block {
            return true
        }
        return false
    }

    private func paragraphInlines(_ block: ReaderBlock) -> [ReaderInline] {
        if case .paragraph(let inlines) = block {
            return inlines
        }
        return []
    }

    // MARK: - Galleries as lists

    @Test
    func carouselListBecomesFiguresNotBullets() throws {
        // Splide, Swiper, Flickity and slick all build their track as
        // <ul><li>, so a gallery arrived as one bullet per photo whose text
        // was the photo credit.
        let html = """
        <ul class="splide__list">
          <li class="splide__slide"><figure><img src="https://cdn.example.com/one.jpg" alt="One">
            <figcaption>Creating a new automation</figcaption></figure></li>
          <li class="splide__slide"><figure><img src="https://cdn.example.com/two.jpg" alt="Two">
            <figcaption>Selecting the CarPlay option</figcaption></figure></li>
        </ul>
        """
        let result = try blocks(html)
        #expect(!result.contains(where: isList))
        let figures: [MediaDescriptor] = result.compactMap { block in
            if case .figure(let media) = block {
                return media
            }
            return nil
        }
        #expect(figures.count == 2)
        #expect(figures.first?.caption == "Creating a new automation")
    }

    @Test
    func anOrdinaryListStaysAList() throws {
        let html = """
        <ul>
          <li>Open the Shortcuts app and switch to the Automations tab.</li>
          <li>Scroll down until you find the CarPlay option under NFC.</li>
        </ul>
        """
        let result = try blocks(html)
        guard case .list(_, let items)? = result.first else {
            Issue.record("Expected a list, got \(result)")
            return
        }
        #expect(items.count == 2)
    }

    @Test
    func aListOfProseWithInlineIconsStaysAList() throws {
        // Media presence alone must not turn a list into a gallery.
        let html = """
        <ul>
          <li><img src="https://cdn.example.com/icon.png"> Open the Shortcuts app and switch to the
              Automations tab at the bottom of the screen, then tap the plus button.</li>
          <li><img src="https://cdn.example.com/icon2.png"> Scroll down until you find the CarPlay
              option, which sits underneath NFC in the list of triggers.</li>
        </ul>
        """
        let result = try blocks(html)
        #expect(result.contains(where: isList))
    }

    // MARK: - Duplicate images at different CDN sizes

    @Test
    func sameImageAtTwoSizesAppearsOnce() throws {
        // A gallery emits each photo twice: once in the carousel and once in
        // the thumbnail rail, differing only by resize parameters.
        let html = """
        <div>
          <figure><img src="https://cdn.example.com/wp/img_5030.jpeg?w=1736&h=1157"></figure>
          <figure><img src="https://cdn.example.com/wp/img_5030.jpeg?w=750&h=422"></figure>
        </div>
        """
        let figures = sanitizeBlocks(try blocks(html)).filter(isFigure)
        #expect(figures.count == 1)
    }

    @Test
    func differentImagesAreBothKept() throws {
        let html = """
        <div>
          <figure><img src="https://cdn.example.com/wp/img_5030.jpeg?w=750"></figure>
          <figure><img src="https://cdn.example.com/wp/img_5031.jpeg?w=750"></figure>
        </div>
        """
        let figures = sanitizeBlocks(try blocks(html)).filter(isFigure)
        #expect(figures.count == 2)
    }

    @Test
    func mediaIdentityIgnoresResizeParametersOnly() {
        #expect(mediaIdentity("https://cdn.example.com/a/b.jpg?w=100") == mediaIdentity("https://cdn.example.com/a/b.jpg?w=900"))
        #expect(mediaIdentity("https://cdn.example.com/a/b.jpg") != mediaIdentity("https://cdn.example.com/a/c.jpg"))
        // A CDN that encodes the original URL in the path stays distinguishable.
        #expect(
            mediaIdentity("https://cdn.example.com/fetch/w_424/https%3A%2F%2Fx.com%2F1.png")
                != mediaIdentity("https://cdn.example.com/fetch/w_424/https%3A%2F%2Fx.com%2F2.png")
        )
    }

    // MARK: - Form-driven widgets

    @Test
    func radioDrivenQuizIsRemovedWhole() throws {
        // Pure-CSS quizzes stack every panel in the DOM and reveal one with
        // :checked. Stripping the inputs alone left all eight questions and
        // both explanations for each.
        let html = page("""
            <article>
              \(filler)
              <div class="vq">
                <input type="radio" name="q1"><input type="radio" name="q1">
                <input type="radio" name="q2"><input type="radio" name="q2">
                <section class="vq-panel"><p>What is planned obsolescence?</p>
                  <p>Correct! Planned obsolescence is a deliberate strategy.</p>
                  <p>Not quite. Planned obsolescence limits a product's lifespan.</p>
                </section>
              </div>
            </article>
            """)
        let text = try extract(html).plainText
        #expect(!text.contains("Correct!"))
        #expect(!text.contains("Not quite"))
        #expect(!text.contains("planned obsolescence"))
        #expect(text.contains("Setting this up looks harder"))
    }

    @Test
    func aPageThatIsMostlyAFormIsNotEmptied() throws {
        // The guard: if the control group dominates the document it is the
        // content, so removing it would leave nothing.
        let html = page("""
            <article>
              <div class="survey">
                <input type="radio" name="a"><input type="radio" name="a">
                <input type="radio" name="b"><input type="radio" name="b">
                <p>Question one of our reader survey, which is the whole point of this page.</p>
                <p>Question two of our reader survey, also central to why the page exists.</p>
                <p>Question three, rounding out a page that is genuinely a questionnaire.</p>
              </div>
            </article>
            """)
        #expect(try extract(html).plainText.contains("reader survey"))
    }

    @Test
    func aCoupleOfCheckboxesDoNotTriggerWidgetRemoval() throws {
        let html = page("""
            <article>\(filler)<div><input type="checkbox"> <span>Remember me</span></div></article>
            """)
        #expect(try extract(html).plainText.contains("Setting this up looks harder"))
    }

    // MARK: - Hidden content and publisher markers

    @Test
    func contentTheBrowserReportedAsHiddenIsDropped() throws {
        // annotateHiddenContent resolves computed styles in the capture
        // WebView and marks what the page is not showing.
        let html = page("""
            <article>
              \(filler)
              <section data-stower-hidden="1"><p>Panel three of eight, never on screen.</p></section>
            </article>
            """)
        #expect(!(try extract(html).plainText.contains("Panel three")))
    }

    @Test
    func dataNosnippetFurnitureIsDropped() throws {
        let html = page("""
            <article>
              <div data-nosnippet><p>Nathaniel is a tech enthusiast who dives deep into Apple's world.</p></div>
              \(filler)
            </article>
            """)
        let text = try extract(html).plainText
        #expect(!text.contains("tech enthusiast"))
        #expect(text.contains("Setting this up looks harder"))
    }

    @Test
    func authorBioBlockIsDropped() throws {
        let html = page("""
            <article>
              <div class="author-bio"><p>Nathaniel writes about Apple hardware and software.</p></div>
              \(filler)
            </article>
            """)
        #expect(!(try extract(html).plainText.contains("writes about Apple")))
    }

    @Test
    func menuAndTabChromeIsDropped() throws {
        let html = page("""
            <article>
              \(filler)
              <div role="menu"><span role="menuitem">Preferred Source</span></div>
              <div role="tablist"><span role="tab">Summary</span></div>
            </article>
            """)
        let text = try extract(html).plainText
        #expect(!text.contains("Preferred Source"))
        #expect(!text.contains("Summary"))
    }

    // MARK: - Leading metadata echoes

    @Test
    func dropsALeadingSiteNameEcho() {
        let blocks: [ReaderBlock] = [
            .paragraph([.text("How-To Geek")]),
            .paragraph([.text("When you use CarPlay, you probably just start some music.")]),
        ]
        let result = removeLeadingTitleRepeat(blocks, title: "Some title", siteName: "How-To Geek")
        #expect(result.count == 1)
    }

    @Test
    func dropsALeadingBylineEcho() {
        let blocks: [ReaderBlock] = [
            .paragraph([.text("Nate Pangaro")]),
            .paragraph([.text("When you use CarPlay, you probably just start some music.")]),
        ]
        let result = removeLeadingTitleRepeat(blocks, title: "T", siteName: nil, author: "Nate Pangaro")
        #expect(result.count == 1)
    }

    @Test
    func keepsARealParagraphThatMentionsTheSiteName() {
        let body = "How-To Geek has covered CarPlay for years, and this trick is one of the best."
        let blocks: [ReaderBlock] = [.paragraph([.text(body)])]
        let result = removeLeadingTitleRepeat(blocks, title: "T", siteName: "How-To Geek")
        #expect(result.count == 1)
        #expect(inlineText(paragraphInlines(result[0])) == body)
    }

    @Test
    func onlyStripsEchoesAtTheVeryTop() {
        let blocks: [ReaderBlock] = [
            .paragraph([.text("Real opening paragraph of the article goes here.")]),
            .paragraph([.text("How-To Geek")]),
        ]
        #expect(removeLeadingTitleRepeat(blocks, title: "T", siteName: "How-To Geek").count == 2)
    }
}
