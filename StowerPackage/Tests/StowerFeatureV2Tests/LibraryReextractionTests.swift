import ComposableArchitecture
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

/// Coverage for the bulk re-extract maintenance action, which rebuilds saved
/// articles through the current capture pipeline. Extraction improvements only
/// apply at save time, so articles saved by an older build keep that build's
/// structure until they are rebuilt.
@MainActor
@Suite
struct LibraryReextractionTests {
    private func item(_ title: String, url: String?) -> SavedItem {
        var item = SavedItem(title: title, content: "Body")
        item.sourceURL = url
        return item
    }

    private func saveResult(_ item: SavedItem) -> ArticleSaveResult {
        ArticleSaveResult(item: item, state: .ready)
    }

    @Test
    func rebuildsEveryURLBackedArticleAndReportsProgress() async {
        let first = item("First", url: "https://example.com/one")
        let second = item("Second", url: "https://example.com/two")
        let refreshed = LockIsolated<[UUID]>([])

        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.stowerRepository.fetchReextractableItems = { [first, second] }
            $0.articleSaveClient.refresh = { id, _ in
                refreshed.withValue { $0.append(id) }
                return ArticleSaveResult(item: SavedItem(title: "x", content: "y"), state: .ready)
            }
        }

        await store.send(.reextractLibraryTapped) {
            $0.reextraction = .running(LibraryReextractionState.Progress())
        }
        await store.receive(.reextractStarted(total: 2)) {
            $0.reextraction = .running(.init(completed: 0, total: 2))
        }
        await store.receive(.reextractItemFinished(title: "First", succeeded: true)) {
            $0.reextraction = .running(.init(completed: 1, total: 2, currentTitle: "First"))
        }
        await store.receive(.reextractItemFinished(title: "Second", succeeded: true)) {
            $0.reextraction = .running(.init(completed: 2, total: 2, currentTitle: "Second"))
        }
        await store.receive(.reextractCompleted(wasCancelled: false)) {
            $0.reextraction = .finished(.init(succeeded: 2, failed: 0, wasCancelled: false))
        }

        #expect(refreshed.value == [first.id, second.id])
    }

    @Test
    func oneUnreachableArticleDoesNotStopTheRebuild() async {
        // A paywalled or offline article must not end the run — the whole
        // point is to repair a library in one pass.
        let broken = item("Broken", url: "https://example.com/broken")
        let healthy = item("Healthy", url: "https://example.com/healthy")
        let attempted = LockIsolated<[UUID]>([])

        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.stowerRepository.fetchReextractableItems = { [broken, healthy] }
            $0.articleSaveClient.refresh = { id, _ in
                attempted.withValue { $0.append(id) }
                if id == broken.id {
                    throw URLError(.timedOut)
                }
                return ArticleSaveResult(item: SavedItem(title: "x", content: "y"), state: .ready)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.reextractLibraryTapped)
        await store.receive(.reextractStarted(total: 2))
        await store.receive(.reextractItemFinished(title: "Broken", succeeded: false))
        await store.receive(.reextractItemFinished(title: "Healthy", succeeded: true))
        await store.receive(.reextractCompleted(wasCancelled: false)) {
            $0.reextraction = .finished(.init(succeeded: 1, failed: 1, wasCancelled: false))
        }

        #expect(attempted.value == [broken.id, healthy.id])
    }

    @Test
    func anEmptyLibraryFinishesImmediately() async {
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.stowerRepository.fetchReextractableItems = { [] }
        }

        await store.send(.reextractLibraryTapped) {
            $0.reextraction = .running(LibraryReextractionState.Progress())
        }
        // `total` is already 0, so this carries no observable change.
        await store.receive(.reextractStarted(total: 0))
        await store.receive(.reextractCompleted(wasCancelled: false)) {
            $0.reextraction = .finished(.init(succeeded: 0, failed: 0, wasCancelled: false))
        }
    }

    @Test
    func stoppingKeepsWhatWasAlreadyRebuilt() async {
        let first = item("First", url: "https://example.com/one")
        let second = item("Second", url: "https://example.com/two")

        // The second refresh parks on a test clock that is never advanced,
        // so the run is genuinely mid-flight when Stop is tapped.
        let clock = TestClock()
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.stowerRepository.fetchReextractableItems = { [first, second] }
            $0.articleSaveClient.refresh = { id, _ in
                if id == second.id {
                    try await clock.sleep(for: .seconds(60))
                }
                return ArticleSaveResult(item: SavedItem(title: "x", content: "y"), state: .ready)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.reextractLibraryTapped)
        await store.receive(.reextractStarted(total: 2))
        await store.receive(.reextractItemFinished(title: "First", succeeded: true))

        await store.send(.reextractCancelTapped) {
            $0.reextraction = .finished(.init(succeeded: 1, failed: 0, wasCancelled: true))
        }
    }

    @Test
    func tappingRebuildTwiceDoesNotStartASecondRun() async {
        let only = item("Only", url: "https://example.com/one")

        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.stowerRepository.fetchReextractableItems = { [only] }
            $0.articleSaveClient.refresh = { _, _ in
                ArticleSaveResult(item: SavedItem(title: "x", content: "y"), state: .ready)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.reextractLibraryTapped)
        await store.receive(.reextractStarted(total: 1))
        // Ignored while a run is in flight.
        await store.send(.reextractLibraryTapped)
        await store.receive(.reextractItemFinished(title: "Only", succeeded: true))
        await store.receive(.reextractCompleted(wasCancelled: false))

        await store.send(.reextractDismissed) {
            $0.reextraction = .idle
        }
    }

    @Test
    func progressFractionIsSafeWhenTotalIsUnknown() {
        #expect(LibraryReextractionState.Progress(completed: 0, total: 0).fraction == 0)
        #expect(LibraryReextractionState.Progress(completed: 1, total: 4).fraction == 0.25)
    }
}

/// The failure banner has to name the failing import, not just count it.
@Suite
struct FailedImportTests {
    @Test
    func describesAURLJobByHostAndPath() {
        let job = IngestionJob(
            kind: .url,
            payload: "https://www.example.com/posts/why-formatting-matters?utm=1",
            id: UUID(0),
            createdAt: Date(timeIntervalSince1970: 0),
            status: .failed,
            claimedAt: nil,
            attemptCount: 3,
            lastError: "The request timed out."
        )
        let failure = FailedImport(job: job)
        #expect(failure.label == "example.com/posts/why-formatting-matters")
        #expect(failure.reason == "The request timed out.")
    }

    @Test
    func truncatesVeryLongURLsInTheMiddle() {
        let long = "https://example.com/" + String(repeating: "segment/", count: 20) + "end"
        let label = FailedImport.displayURL(long)
        #expect(label.count < 60)
        #expect(label.hasPrefix("example.com/"))
        #expect(label.hasSuffix("end"))
    }

    @Test
    func describesAFileJobByFilename() {
        let job = IngestionJob(
            kind: .pdf,
            payload: "/private/group/PendingPDFs/2A3F/Quarterly Report.pdf",
            id: UUID(1),
            createdAt: Date(timeIntervalSince1970: 0),
            status: .failed,
            claimedAt: nil,
            attemptCount: 3,
            lastError: nil
        )
        let failure = FailedImport(job: job)
        #expect(failure.label == "Quarterly Report.pdf")
        #expect(failure.reason == nil)
    }

    @Test
    func doesNotShowRawJSONForTextJobs() {
        let job = IngestionJob(
            kind: .text,
            payload: #"{"content":"a note","mode":"auto"}"#,
            id: UUID(2),
            createdAt: Date(timeIntervalSince1970: 0),
            status: .failed,
            claimedAt: nil,
            attemptCount: 3,
            lastError: "  "
        )
        let failure = FailedImport(job: job)
        #expect(failure.label == "Imported text")
        // Whitespace-only errors are not worth showing.
        #expect(failure.reason == nil)
    }
}
