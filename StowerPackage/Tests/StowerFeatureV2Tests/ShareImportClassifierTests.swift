import Foundation
@testable import StowerData
import Testing

@Suite
struct ShareImportClassifierTests {
    @Test
    func classifyTreatsSingleURLAsURLImport() {
        let result = SharedTextClassifier.classify("https://example.com/article")

        switch result {
        case .singleURL(let url):
            #expect(url.absoluteString == "https://example.com/article")
        case .text:
            Issue.record("Expected a single URL classification.")
        }
    }

    @Test
    func classifyKeepsProseWithIncidentalLinksAsText() {
        let result = SharedTextClassifier.classify(
            "Here is a note about https://example.com/article that should stay as text."
        )

        switch result {
        case .singleURL:
            Issue.record("Expected prose with an incidental URL to stay text.")
        case .text(let payload):
            #expect(payload.mode == .auto)
            #expect(payload.content.contains("Here is a note"))
        }
    }

    @Test
    func importModeUsesMarkdownForMarkdownFilesAndAutoForTxt() {
        #expect(TextImportDetector.importMode(for: URL(fileURLWithPath: "/tmp/notes.md")) == .markdown)
        #expect(TextImportDetector.importMode(for: URL(fileURLWithPath: "/tmp/notes.markdown")) == .markdown)
        #expect(TextImportDetector.importMode(for: URL(fileURLWithPath: "/tmp/notes.txt")) == .auto)
    }
}
