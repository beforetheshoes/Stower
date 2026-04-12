import Foundation
@testable import StowerFeature
import Testing

@Suite
struct ReaderSpeechTextBuilderTests {
    @Test
    func speechBlocks_excludesMediaAndCode_includesTextualBlocks() {
        let document = ReaderDocument(
            title: "Title",
            blocks: [
                .heading(level: 2, inlines: [.text("Heading")]),
                .paragraph([.text("Hello"), .text("world")]),
                .list(ordered: false, items: [
                    [.text("First")],
                    [.text("Second")],
                ]),
                .blockquote([.text("Quote")]),
                .callout(title: "Note", inlines: [.text("Callout body")]),
                .code(language: "swift", code: "print(\"hi\")"),
                .horizontalRule,
                .figure(media: MediaDescriptor(kind: .image, sourceURL: "https://example.com/a.png")),
            ]
        )

        let blocks = ReaderSpeechTextBuilder.speechBlocks(document: document)

        #expect(blocks.map(\.kind) == [.heading, .paragraph, .list, .blockquote, .callout])
        #expect(blocks.map(\.index) == [0, 1, 2, 3, 4])

        #expect(blocks[0].text == "Heading")
        #expect(blocks[1].text == "Hello world")
        #expect(blocks[2].text == "First\nSecond")
        #expect(blocks[3].text == "Quote")
        #expect(blocks[4].text == "Note. Callout body")
    }
}
