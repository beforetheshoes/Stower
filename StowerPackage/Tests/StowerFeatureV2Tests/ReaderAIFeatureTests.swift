import ComposableArchitecture
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@MainActor
@Suite
struct ReaderAIFeatureTests {
    @Test
    func liveClientKeepsPrivateCloudComputeDisabled() {
        #expect(
            ArticleAIClient.live.enhancedAvailability()
                == .other("Enhanced summaries are currently disabled.")
        )
    }

    @Test
    func appeared_withCachedSummary_populatesStateAsCached() async {
        let itemID = UUID()
        let cached = CachedSummary(text: "Cached summary text.", generatedAt: Date(timeIntervalSince1970: 100))

        let fakeAI = ArticleAIClient(
            availability: { .available },
            prewarm: {},
            summarize: { _, _ in AsyncThrowingStream { $0.finish() } },
            ask: { _, _, _ in AsyncThrowingStream { $0.finish() } },
            enhancedAvailability: { .available }
        )

        let store = TestStore(initialState: ReaderAIFeature.State()) {
            ReaderAIFeature()
        } withDependencies: {
            $0.articleAIClient = fakeAI
            $0.stowerRepository.loadSummary = { _, _, _ in cached }
        }

        await store.send(.appeared(itemID: itemID)) {
            $0.itemID = itemID
            $0.availability = .available
        }

        await store.receive(
            .cacheLoaded(
                quality: .quick,
                text: cached.text,
                generatedAt: cached.generatedAt
            )
        ) {
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
            prewarm: {},
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
            $0.stowerRepository.loadSummary = { _, _, _ in nil }
            $0.stowerRepository.saveSummary = { _, quality, version, text in
                #expect(quality == ArticleAIClient.SummaryQuality.quick.rawValue)
                #expect(version == 1)
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
            prewarm: {},
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
            $0.stowerRepository.loadSummary = { _, _, _ in nil }
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
            prewarm: {},
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
            $0.stowerRepository.loadSummary = { _, _, _ in nil }
            $0.stowerRepository.saveSummary = { _, _, _, _ in }
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
            prewarm: {},
            summarize: { _, _ in AsyncThrowingStream { $0.finish() } },
            ask: { _, _, _ in AsyncThrowingStream { $0.finish() } },
            enhancedAvailability: { .available }
        )

        let store = TestStore(initialState: initial) {
            ReaderAIFeature()
        } withDependencies: {
            $0.articleAIClient = fakeAI
            $0.stowerRepository.loadSummary = { _, _, _ in nil }
        }

        await store.send(.cancelAll) {
            $0.isSummarizing = false
            $0.isAnswering = false
            $0.isRetrieving = false
            $0.summaryStage = nil
        }
    }

    @Test
    func selectingEnhancedLoadsItsOwnCacheAndPrewarmsPCC() async {
        let itemID = UUID()
        let didPrewarm = LockIsolated(false)
        let requestedCache = LockIsolated<(String, Int)?>(nil)
        let cached = CachedSummary(
            text: "A deeper cached summary.",
            generatedAt: Date(timeIntervalSince1970: 200),
            quality: "enhanced",
            promptVersion: 7
        )
        let fakeAI = ArticleAIClient(
            availability: { .available },
            prewarm: {},
            summarize: { _, _ in AsyncThrowingStream { $0.finish() } },
            ask: { _, _, _ in AsyncThrowingStream { $0.finish() } },
            enhancedAvailability: { .available },
            prewarmEnhanced: { didPrewarm.setValue(true) },
            summaryPromptVersion: { $0 == .enhanced ? 7 : 2 }
        )

        var initial = ReaderAIFeature.State()
        initial.itemID = itemID
        initial.summaryText = "Quick summary"
        let store = TestStore(initialState: initial) {
            ReaderAIFeature()
        } withDependencies: {
            $0.articleAIClient = fakeAI
            $0.stowerRepository.loadSummary = { _, quality, version in
                requestedCache.setValue((quality, version))
                return cached
            }
        }

        await store.send(.summaryQualityChanged(.enhanced)) {
            $0.summaryQuality = .enhanced
            $0.summaryResultQuality = .enhanced
            $0.summaryText = ""
        }
        await store.receive(
            .cacheLoaded(
                quality: .enhanced,
                text: cached.text,
                generatedAt: cached.generatedAt
            )
        ) {
            $0.summaryText = cached.text
            $0.summaryGeneratedAt = cached.generatedAt
            $0.summaryWasCached = true
        }

        #expect(didPrewarm.value)
        #expect(requestedCache.value?.0 == "enhanced")
        #expect(requestedCache.value?.1 == 7)
    }

    @Test
    func enhancedFallbackIsPersistedAsQuick() async {
        let itemID = UUID()
        let saved = LockIsolated<(String, Int, String)?>(nil)
        let fakeAI = ArticleAIClient(
            availability: { .available },
            prewarm: {},
            summarize: { _, _ in AsyncThrowingStream { $0.finish() } },
            ask: { _, _, _ in AsyncThrowingStream { $0.finish() } },
            enhancedAvailability: { .available },
            summarizeEnhanced: { _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.started)
                    continuation.yield(.qualityResolved(.quick))
                    continuation.yield(.stage("Continuing on device"))
                    continuation.yield(.finished("Quick fallback result"))
                    continuation.finish()
                }
            },
            summaryPromptVersion: { $0 == .enhanced ? 7 : 2 }
        )

        var initial = ReaderAIFeature.State()
        initial.itemID = itemID
        initial.summaryQuality = .enhanced
        initial.summaryResultQuality = .enhanced
        let store = TestStore(initialState: initial) {
            ReaderAIFeature()
        } withDependencies: {
            $0.articleAIClient = fakeAI
            $0.stowerRepository.saveSummary = { _, quality, version, text in
                saved.setValue((quality, version, text))
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.summarizeRequested(document: nil, plainText: "Article"))
        await store.receive(.summaryEvent(.finished("Quick fallback result")))
        await store.finish()

        #expect(store.state.summaryResultQuality == .quick)
        #expect(saved.value?.0 == "quick")
        #expect(saved.value?.1 == 2)
        #expect(saved.value?.2 == "Quick fallback result")
    }

    @Test
    func panelOpened_refreshesAvailabilityAndPrewarms() async {
        let didPrewarm = LockIsolated(false)
        let fakeAI = ArticleAIClient(
            availability: { .modelNotReady },
            prewarm: { didPrewarm.setValue(true) },
            summarize: { _, _ in AsyncThrowingStream { $0.finish() } },
            ask: { _, _, _ in AsyncThrowingStream { $0.finish() } },
            enhancedAvailability: { .available }
        )
        let store = TestStore(initialState: ReaderAIFeature.State()) {
            ReaderAIFeature()
        } withDependencies: {
            $0.articleAIClient = fakeAI
        }

        await store.send(.panelOpened) {
            $0.availability = .modelNotReady
        }
        #expect(didPrewarm.value)
    }
}
