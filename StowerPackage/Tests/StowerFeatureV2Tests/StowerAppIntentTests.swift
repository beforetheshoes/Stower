import Dependencies
import Foundation
@testable import StowerFeature
import Testing

@Suite
struct StowerAppIntentTests {
    @Test
    func saveURLValidatesAndEnqueues() async throws {
        let captured = LockIsolated<URL?>(nil)
        let validURL = try #require(URL(string: "https://example.com/article"))

        try await withDependencies {
            $0.appIntentIngestionClient.enqueueURL = { captured.setValue($0) }
        } operation: {
            _ = try await SaveURLToStowerIntent(url: validURL).perform()
        }
        #expect(captured.value == validURL)
    }

    @Test
    func saveURLRejectsUnsupportedSchemes() async {
        let fileURL = URL(fileURLWithPath: "/tmp/article")
        await #expect(throws: StowerIntentError.self) {
            _ = try await SaveURLToStowerIntent(url: fileURL).perform()
        }
    }

    @Test
    func saveTextTrimsAndEnqueues() async throws {
        let captured = LockIsolated<String?>(nil)
        try await withDependencies {
            $0.appIntentIngestionClient.enqueueText = { captured.setValue($0) }
        } operation: {
            _ = try await SaveTextToStowerIntent(text: "  A saved thought.  ").perform()
        }
        #expect(captured.value == "A saved thought.")
    }

    @Test
    func saveTextRejectsWhitespace() async {
        await #expect(throws: StowerIntentError.self) {
            _ = try await SaveTextToStowerIntent(text: " \n ").perform()
        }
    }
}
