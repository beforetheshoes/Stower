import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct ReaderHTMLSourceTests {
    private let item = SavedItem(title: "Title", content: "Body")
    private let document = ReaderDocument(
        title: "Title",
        blocks: [
            .heading(level: 2, inlines: [.text("Section")]),
            .paragraph([.text("First paragraph.")]),
            .paragraph([.text("Second paragraph.")]),
        ]
    )

    @Test
    func readyHTMLIsPassedThroughUntouched() async {
        let html = "<html><body>captured</body></html>"
        #expect(await ReaderHTMLSource.ready(html).build() == html)
    }

    @Test
    func aDocumentBuildsTheSameHTMLAsTheBuilderCalledDirectly() async {
        let appearance = ReaderAppearanceSettings(background: .sepia)
        let insets = ReaderInsets(top: 44, bottom: 20)

        let built = await ReaderHTMLSource.document(
            ReaderDocumentPage(
                item: item,
                document: document,
                appearance: appearance,
                pageWidth: 390,
                fontScale: 1.2,
                restoreBlockIndex: 2,
                insets: insets
            )
        )
        .build()

        let direct = ReaderDocumentHTMLBuilder.buildReaderHTML(
            item: item,
            document: document,
            appearance: appearance,
            pageWidth: 390,
            fontScale: 1.2,
            restoreBlockIndex: 2,
            insets: insets
        )
        #expect(built == direct)
        #expect(built.contains("Second paragraph."))
    }
}
