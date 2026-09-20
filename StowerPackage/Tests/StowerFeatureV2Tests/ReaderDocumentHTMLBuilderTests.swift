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

    @Test
    func bookImagesAreServedByFilenameEvenWithoutALocalPath() {
        let item = SavedItem(
            title: "Book",
            content: "Body",
            canonicalURL: SavedItem.importedBookURLPrefix + "abc",
            renderFormat: .structuredV1
        )
        let document = ReaderDocument(
            title: "Book",
            blocks: [
                // As rebuilt on a second device: the marker survives, the
                // local path does not.
                .figure(media: MediaDescriptor(kind: .image, sourceURL: "stower://epub-image/epub-img-4.png")),
                .figure(media: MediaDescriptor(kind: .image, sourceURL: "stower://epub-image/../document.pdf")),
            ]
        )

        let html = ReaderDocumentHTMLBuilder.buildReaderHTML(
            item: item,
            document: document,
            appearance: ReaderAppearanceSettings(),
            pageWidth: 375
        )

        #expect(html.contains("<img src=\"epub-img-4.png\""))
        #expect(!html.contains("document.pdf"))
    }

    private func html(for blocks: [ReaderBlock]) -> String {
        ReaderDocumentHTMLBuilder.buildReaderHTML(
            item: SavedItem(title: "Doc", content: "Body", renderFormat: .structuredV1),
            document: ReaderDocument(title: "Doc", blocks: blocks),
            appearance: ReaderAppearanceSettings(),
            pageWidth: 375
        )
    }

    @Test
    func nestedListMarkersBecomeNestedLists() {
        let html = html(for: [
            .list(ordered: false, items: [
                [.text("Fruit")],
                [.text("— "), .text("Apple")],
                [.text("— "), .text("— "), .text("Fuji")],
                [.text("— Pear")],
                [.text("Veg")],
            ]),
        ])

        #expect(html.contains(
            "<li>Fruit<ul><li>Apple<ul><li>Fuji</li></ul></li><li>Pear</li></ul></li><li>Veg</li></ul>"
        ))
    }

    @Test
    func nestedOrderedListsRestartNumberingAndFirstItemKeepsItsDash() {
        let html = html(for: [
            .list(ordered: true, items: [
                [.text("— said quietly")],
                [.text("— "), .text("sub-step")],
                [.text("— "), .text("— "), .text("— "), .text("too deep")],
            ]),
        ])

        // Depth can only grow one level at a time.
        #expect(html.contains(
            "<li>— said quietly<ol><li>sub-step<ol><li>too deep</li></ol></li></ol></li></ol>"
        ))
    }

    @Test
    func linksWithinTheDocumentScrollInPlace() {
        let html = html(for: [
            .paragraph([
                .link(label: "1", url: "#stower-block-7"),
                .link(label: "out", url: "https://example.com"),
            ]),
        ])

        #expect(html.contains("<a href=\"#stower-block-7\">1</a>"))
        #expect(html.contains("<a href=\"https://example.com\" target=\"_blank\""))
    }
}
