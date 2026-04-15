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
}
