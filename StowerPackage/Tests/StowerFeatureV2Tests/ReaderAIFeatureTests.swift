import ComposableArchitecture
import Foundation
import Testing
@testable import StowerData
@testable import StowerFeature

@MainActor
@Suite
struct ReaderAIFeatureTests {
    @Test
    func appeared_withCachedSummary_populatesStateAsCached() async {
        let itemID = UUID()
        let cached = CachedSummary(text: "Cached summary text.", generatedAt: Date(timeIntervalSince1970: 100))

        let fakeAI = ArticleAIClient(
            availability: { .available },
            summarize: { _, _ in AsyncThrowingStream { $0.finish() } },
            ask: { _, _, _ in AsyncThrowingStream { $0.finish() } }
        )

        let store = TestStore(initialState: ReaderAIFeature.State()) {
            ReaderAIFeature()
        } withDependencies: {
            $0.articleAIClient = fakeAI
            $0.stowerRepository.loadSummary = { _ in cached }
        }

        await store.send(.appeared(itemID: itemID)) {
            $0.itemID = itemID
            $0.availability = .available
        }

        await store.receive(.cacheLoaded(text: cached.text, generatedAt: cached.generatedAt)) {
            $0.summaryText = cached.text
            $0.summaryGeneratedAt = cached.generatedAt
            $0.summaryWasCached = true
        }
    }

    @Test
    func summarizeRequested_streamsEventsAndPersists() async {
        let itemID = UUID()
        let savedSummary = LockIsolated<String?>(nil)
        let plainText = "A short article to summarize."
        let finalText = "A short summary."

        let fakeAI = ArticleAIClient(
            availability: { .available },
            summarize: { _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.started)
                    continuation.yield(.partial("A short"))
                    continuation.yield(.partial("A short summary."))
                    continuation.yield(.finished(finalText))
                    continuation.finish()
                }
            },
            ask: { _, _, _ in AsyncThrowingStream { $0.finish() } }
        )

        var initial = ReaderAIFeature.State()
        initial.itemID = itemID
        let store = TestStore(initialState: initial) {
            ReaderAIFeature()
        } withDependencies: {
            $0.articleAIClient = fakeAI
            $0.stowerRepository.loadSummary = { _ in nil }
            $0.stowerRepository.saveSummary = { _, text in
                savedSummary.withValue { $0 = text }
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.summarizeRequested(document: nil, plainText: plainText)) {
            $0.isSummarizing = true
            $0.summaryText = ""
            $0.summaryStage = nil
            $0.summaryError = nil
            $0.summaryWasCached = false
            $0.summaryGeneratedAt = nil
        }

        // Drain all the child effect's emitted actions up to finished.
        await store.receive(.summaryEvent(.finished(finalText)))
        await store.finish()

        #expect(store.state.summaryText == finalText)
        #expect(store.state.isSummarizing == false)
        #expect(savedSummary.value == finalText)
    }

    @Test
    func summarizeRequested_whenAIUnavailable_isNoop() async {
        let fakeAI = ArticleAIClient(
            availability: { .appleIntelligenceNotEnabled },
            summarize: { _, _ in
                // Should never be called.
                AsyncThrowingStream { continuation in
                    continuation.yield(.finished("should not happen"))
                    continuation.finish()
                }
            },
            ask: { _, _, _ in AsyncThrowingStream { $0.finish() } }
        )

        var state = ReaderAIFeature.State()
        state.itemID = UUID()
        state.availability = .appleIntelligenceNotEnabled

        let store = TestStore(initialState: state) {
            ReaderAIFeature()
        } withDependencies: {
            $0.articleAIClient = fakeAI
            $0.stowerRepository.loadSummary = { _ in nil }
        }

        // No state mutation, no effect dispatched.
        await store.send(.summarizeRequested(document: nil, plainText: "article body"))
    }

    @Test
    func askSubmitted_appendsTranscriptEntry() async {
        let itemID = UUID()
        let answer = "Yes, the article mentions that."

        let fakeAI = ArticleAIClient(
            availability: { .available },
            summarize: { _, _ in AsyncThrowingStream { $0.finish() } },
            ask: { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.started)
                    continuation.yield(.partial("Yes, the article"))
                    continuation.yield(.finished(answer))
                    continuation.finish()
                }
            }
        )

        var initial = ReaderAIFeature.State()
        initial.itemID = itemID
        initial.question = "Does the article mention coffee?"

        let store = TestStore(initialState: initial) {
            ReaderAIFeature()
        } withDependencies: {
            $0.articleAIClient = fakeAI
            $0.stowerRepository.loadSummary = { _ in nil }
            $0.stowerRepository.saveSummary = { _, _ in }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.askSubmitted(document: nil, plainText: "coffee is mentioned here")) {
            $0.isAnswering = true
            $0.pendingAnswer = ""
            $0.askError = nil
            $0.isRetrieving = false
        }

        await store.receive(.answerEvent(.finished(answer)))
        await store.finish()

        #expect(store.state.transcript.count == 1)
        #expect(store.state.transcript.first?.answer == answer)
        #expect(store.state.transcript.first?.question == "Does the article mention coffee?")
        #expect(store.state.question.isEmpty)
        #expect(store.state.isAnswering == false)
    }

    @Test
    func cancelAll_resetsInflightState() async {
        var initial = ReaderAIFeature.State()
        initial.isSummarizing = true
        initial.isAnswering = true
        initial.isRetrieving = true
        initial.summaryStage = "Summarizing section 2 of 4"

        let fakeAI = ArticleAIClient(
            availability: { .available },
            summarize: { _, _ in AsyncThrowingStream { $0.finish() } },
            ask: { _, _, _ in AsyncThrowingStream { $0.finish() } }
        )

        let store = TestStore(initialState: initial) {
            ReaderAIFeature()
        } withDependencies: {
            $0.articleAIClient = fakeAI
            $0.stowerRepository.loadSummary = { _ in nil }
        }

        await store.send(.cancelAll) {
            $0.isSummarizing = false
            $0.isAnswering = false
            $0.isRetrieving = false
            $0.summaryStage = nil
        }
    }
}
