import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct ReaderDocumentHTMLBuilderTests {
    @Test
    func buildReaderHTML_includesHorizontalScrollLockRuntime() {
        let item = SavedItem(
            title: "Reader",
            content: "Body",
            sourceURL: "https://example.com/article",
            renderFormat: .structuredV1
        )
        let document = ReaderDocument(
            title: "Reader",
            blocks: [.paragraph([.text("Body")])]
        )

        let html = ReaderDocumentHTMLBuilder.buildReaderHTML(
            item: item,
            document: document,
            appearance: ReaderAppearanceSettings(),
            pageWidth: 375
        )

        #expect(html.contains("window.scrollX"))
        #expect(html.contains("window.scrollTo(0, window.scrollY)"))
        #expect(html.contains("requestAnimationFrame"))
    }

    @Test
    func headerRemainsVisibleAndUsesReadableMetadataOrder() throws {
        let item = SavedItem(
            title: "A Beautiful Article",
            content: "Body",
            sourceURL: "https://example.com/article",
            renderFormat: .structuredV1,
            heroImageURL: "https://example.com/hero.jpg",
            author: "A. Writer",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            siteName: "Example",
            readingTimeMinutes: 7
        )
        let html = ReaderDocumentHTMLBuilder.buildReaderHTML(
            item: item,
            document: ReaderDocument(title: item.title, blocks: [.paragraph([.text("Body")])]),
            appearance: ReaderAppearanceSettings(),
            fontScale: 1.25
        )

        #expect(html.contains("header:not(.stower-header)"))
        #expect(html.contains("font-size: 23.75px"))
        let title = try #require(html.range(of: "<h1 class=\"stower-title\"")?.lowerBound)
        let source = try #require(html.range(of: "<a class=\"stower-source\"")?.lowerBound)
        let meta = try #require(html.range(of: "<div class=\"stower-meta\"")?.lowerBound)
        let hero = try #require(html.range(of: "<img class=\"stower-hero\"")?.lowerBound)
        #expect(title < source)
        #expect(source < meta)
        #expect(meta < hero)
    }
}
