import Foundation
@testable import StowerFeature
import Testing

/// Opt-in semantic checks against the real OS 27 on-device model.
///
/// Foundation Models availability and wording are device-dependent, so these
/// do not run in ordinary CI. Set `STOWER_RUN_FOUNDATION_MODEL_TESTS=1` on an
/// Apple Intelligence-capable Mac to include them in a local `swift test` run.
@Suite(.serialized)
struct FoundationModelsIntegrationTests {
    private static let shouldRun =
        ProcessInfo.processInfo.environment["STOWER_RUN_FOUNDATION_MODEL_TESTS"] == "1"

    private static let article = """
        The Harbor School installed solar panels and a battery in March. The
        project supplies about sixty percent of the school building's annual
        electricity and keeps the library open during short power outages.
        Students helped compare proposals, but the city paid for construction
        with a resilience grant. The school expects the equipment to save
        roughly forty thousand dollars each year. It will use those savings
        to expand its free after-school tutoring program.
        """

    @Test
    func fixedArticleSummaryRetainsTheCentralFacts() async throws {
        guard Self.shouldRun else { return }
        let client = try Self.availableClient()

        let summary = try await Self.finalSummary(from: client, text: Self.article)
            .lowercased()
        #expect(summary.contains("solar"))
        #expect(summary.contains("school"))
        #expect(summary.contains("tutor") || summary.contains("after-school"))
    }

    @Test
    func fixedArticleQuestionAnswerIsGrounded() async throws {
        guard Self.shouldRun else { return }
        let client = try Self.availableClient()

        let answer = try await Self.finalAnswer(
            from: client,
            text: Self.article,
            question: "Who paid for construction, and what will the savings fund?"
        )
        .lowercased()
        #expect(answer.contains("city"))
        #expect(answer.contains("grant"))
        #expect(answer.contains("tutor") || answer.contains("after-school"))
    }

    @Test
    func oversizedArticleUsesChunkingAndStillFinishes() async throws {
        guard Self.shouldRun else { return }
        let client = try Self.availableClient()
        let oversized = Array(repeating: Self.article, count: 160)
            .joined(separator: "\n\n")
        var sawChunking = (false)
        var final = ""

        for try await event in client.summarize(nil, oversized) {
            switch event {
            case .stage:
                sawChunking = true
            case .finished(let text):
                final = text
            case .started, .qualityResolved, .partial:
                break
            }
        }

        #expect(sawChunking)
        #expect(!final.isEmpty)
    }

    @Test
    func cancellingGenerationTerminatesTheConsumerTask() async throws {
        guard Self.shouldRun else { return }
        let client = try Self.availableClient()
        let oversized = Array(repeating: Self.article, count: 160)
            .joined(separator: "\n\n")
        let task = Task {
            for try await _ in client.summarize(nil, oversized) {}
        }

        task.cancel()
        _ = await task.result
        #expect(task.isCancelled)
    }

    private static func availableClient() throws -> ArticleAIClient {
        let client = ArticleAIClient.live
        guard client.availability() == .available else {
            throw IntegrationError.modelUnavailable
        }
        return client
    }

    private static func finalSummary(
        from client: ArticleAIClient,
        text: String
    ) async throws -> String {
        var final = ""
        for try await event in client.summarize(nil, text) {
            if case .finished(let text) = event {
                final = text
            }
        }
        return final
    }

    private static func finalAnswer(
        from client: ArticleAIClient,
        text: String,
        question: String
    ) async throws -> String {
        var final = ""
        for try await event in client.ask(nil, text, question) {
            if case .finished(let text) = event {
                final = text
            }
        }
        return final
    }

    private enum IntegrationError: LocalizedError {
        case modelUnavailable

        var errorDescription: String? {
            "The OS 27 on-device language model is unavailable on this Mac."
        }
    }
}
