import Foundation
@testable import StowerFeature
import SwiftSoup
import Testing

/// The reader highlights and scrolls by block index, but the two sides of that
/// contract are produced independently: listening counts positions in
/// `ReaderDocument.blocks`, while the page on screen for a captured article is
/// the extractor's HTML, numbered by `addBlockIndices`. These tests pin the two
/// index spaces together.
@Suite
struct ReaderBlockIndexAlignmentTests {
    private let sourceURL = URL(string: "https://www.example.com/an-article")!

    private func page(_ body: String) -> String {
        """
        <!doctype html><html><head><meta property="og:title" content="An article">
        <meta property="og:site_name" content="Example"></head>
        <body>\(body)</body></html>
        """
    }

    private func indexedElements(_ readerHTML: String) throws -> [(index: Int, tag: String, text: String)] {
        let document = try SwiftSoup.parse(readerHTML, sourceURL.absoluteString)
        return try document.select("[data-block-index]").array().compactMap { element in
            guard let index = Int((try? element.attr("data-block-index")) ?? "") else { return nil }
            return (index, element.tagName(), cleanText((try? element.text()) ?? ""))
        }
    }

    // MARK: - The header must not occupy a body index

    @Test
    func headerIsNotBlockZero() throws {
        // `querySelector` returns the first match in document order, so a
        // header sharing index 0 with the opening paragraph meant every
        // highlight or restore of block 0 landed on the title.
        let html = page("<article><p>The opening paragraph of the article body goes here.</p></article>")
        let readerHTML = try RenderedArticleExtractor.extract(renderedHTML: html, sourceURL: sourceURL).readerHTML

        let elements = try indexedElements(readerHTML)
        let header = try #require(elements.first { $0.tag == "h1" })
        #expect(header.index == -1)

        let zero = try #require(elements.first { $0.index == 0 })
        #expect(zero.tag == "p")
        #expect(zero.text.hasPrefix("The opening paragraph"))
    }

    // MARK: - Granularity must match the block parser

    @Test
    func aListIsOneIndexNotOnePerItem() throws {
        let html = page("""
            <article>
              <p>An opening paragraph long enough to clear the extractor minimum.</p>
              <ul><li>First step</li><li>Second step</li><li>Third step</li></ul>
              <p>A closing paragraph that has to line up in both index spaces.</p>
            </article>
            """)
        let readerHTML = try RenderedArticleExtractor.extract(renderedHTML: html, sourceURL: sourceURL).readerHTML
        let body = try indexedElements(readerHTML).filter { $0.index >= 0 }

        #expect(body.map(\.tag) == ["p", "ul", "p"])
        // The block after the list is what used to drift, by the item count.
        #expect(body.last?.index == 2)
        #expect(body.last?.text.hasPrefix("A closing paragraph") == true)
    }

    @Test
    func aBlockquoteContainingParagraphsIsOneIndex() throws {
        let html = page("""
            <article>
              <p>An opening paragraph long enough to clear the extractor minimum.</p>
              <blockquote><p>A quoted sentence.</p><p>And a second quoted sentence.</p></blockquote>
              <p>A closing paragraph after the quotation block.</p>
            </article>
            """)
        let body = try indexedElements(
            try RenderedArticleExtractor.extract(renderedHTML: html, sourceURL: sourceURL).readerHTML
        ).filter { $0.index >= 0 }
        #expect(body.map(\.tag) == ["p", "blockquote", "p"])
    }

    @Test
    func elementsWithNothingInThemAreSkipped() throws {
        let html = page("""
            <article>
              <p>An opening paragraph long enough to clear the extractor minimum.</p>
              <p></p>
              <p>A closing paragraph that should be index one, not index two.</p>
            </article>
            """)
        let body = try indexedElements(
            try RenderedArticleExtractor.extract(renderedHTML: html, sourceURL: sourceURL).readerHTML
        ).filter { $0.index >= 0 }
        #expect(body.count == 2)
        #expect(body.last?.index == 1)
    }

    // MARK: - End-to-end canary

    @Test
    func archiveIndicesLineUpWithDocumentBlocks() async throws {
        // Runs the real capture pipeline: extract, then build the ReaderDocument
        // from the extractor's HTML exactly as WebArticleCaptureSession does.
        let html = page("""
            <article>
              <p>An opening paragraph with enough words in it to survive extraction.</p>
              <h2>A section heading</h2>
              <p>A second paragraph of ordinary prose following the heading.</p>
              <ul><li>First step</li><li>Second step</li><li>Third step</li></ul>
              <blockquote><p>A quotation that spans a couple of sentences here.</p></blockquote>
              <figure><img src="https://cdn.example.com/photo.jpg"><figcaption>A caption.</figcaption></figure>
              <p>A closing paragraph rounding the whole thing off nicely.</p>
            </article>
            """)
        let extraction = try RenderedArticleExtractor.extract(renderedHTML: html, sourceURL: sourceURL)
        let indexed = try await ExtractionPipelineClient.live.extract(extraction.readerHTML, sourceURL)

        let body = try indexedElements(extraction.readerHTML).filter { $0.index >= 0 }
        #expect(body.count == indexed.document.blocks.count)

        // Indices must be a gap-free 0..<n so position and index coincide.
        #expect(body.map(\.index) == Array(0..<body.count))

        // Spot-check that the same index names the same content on both sides.
        for (position, block) in indexed.document.blocks.enumerated() {
            guard position < body.count else { break }
            let documentText = blockText(block).prefix(24)
            guard !documentText.isEmpty else { continue }
            #expect(
                body[position].text.hasPrefix(String(documentText)),
                "index \(position): archive has \(body[position].text.prefix(40)), document has \(documentText)"
            )
        }
    }
}
