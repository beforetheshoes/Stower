import ComposableArchitecture
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct ReaderProgressReportingTests {
    @Test
    func deciderParsesProgressReports() throws {
        let url = try #require(URL(string: "stower-reader://progress?block=42"))
        #expect(ReaderNavigationDecider.progressBlockIndex(from: url) == 42)

        let missing = try #require(URL(string: "stower-reader://progress"))
        #expect(ReaderNavigationDecider.progressBlockIndex(from: missing) == nil)

        let junk = try #require(URL(string: "stower-reader://progress?block=abc"))
        #expect(ReaderNavigationDecider.progressBlockIndex(from: junk) == nil)
    }

    @Test
    func runtimeReportsScrollPositionAndReanchorsOnWidthChange() {
        let script = ReaderWebPageFactory.progressReporterScript
        #expect(script.contains("stower-reader://progress?block="))
        #expect(script.contains("addEventListener('scroll'"))
        // Height-only resizes (toolbars, keyboards) must not move the reader.
        #expect(script.contains("window.innerWidth === lastWidth"))
        #expect(script.contains("stowerScrollToBlock(anchorIndex)"))
    }

    @Test
    func readerHTMLBakesRestorePositionBeforeFirstPaint() {
        let item = SavedItem(title: "Resume", content: "Body")
        let document = ReaderDocument(
            title: "Resume",
            blocks: [
                .paragraph([.text("One")]),
                .paragraph([.text("Two")]),
                .paragraph([.text("Three")]),
            ]
        )

        let resumed = ReaderDocumentHTMLBuilder.buildReaderHTML(
            item: item,
            document: document,
            appearance: ReaderAppearanceSettings(),
            restoreBlockIndex: 2
        )
        #expect(resumed.contains("html { visibility: hidden; }"))
        #expect(resumed.contains("window.__stowerRestoreBlock = 2;"))
        #expect(resumed.contains("document.documentElement.style.visibility = 'visible'"))
        #expect(resumed.contains("stower-reader://progress?block="))

        let fresh = ReaderDocumentHTMLBuilder.buildReaderHTML(
            item: item,
            document: document,
            appearance: ReaderAppearanceSettings(),
            restoreBlockIndex: 0
        )
        #expect(!fresh.contains("visibility: hidden"))
        #expect(!fresh.contains("__stowerRestoreBlock ="))
    }

    @Test
    func readerCSSPadsForSafeAreaAndFadesTheTopEdge() {
        let appearance = ReaderAppearanceSettings()
        let padded = appearance.readerCSS(
            pageWidth: 390,
            insets: ReaderInsets(top: 103, bottom: 34)
        )
        #expect(padded.contains("padding: 123px 20px 94px 20px !important;"))
        #expect(padded.contains("scroll-padding-top: 111px !important;"))
        #expect(padded.contains("body::before"))
        #expect(padded.contains("height: 103px;"))

        let flush = appearance.readerCSS(pageWidth: 390)
        #expect(flush.contains("padding: 20px 20px 60px 20px !important;"))
        #expect(!flush.contains("body::before"))
    }

    @Test
    func progressBarIsReservedAndFillsByBlock() {
        var state = ReaderFeature.State(
            item: SavedItem(title: "Bar", content: "Body", progressUnitCount: 11)
        )
        #expect(state.showsProgressBar)
        #expect(state.progressFraction == 0)

        state.currentBlockIndex = 5
        #expect(state.progressFraction == 0.5)

        state.currentBlockIndex = 10
        #expect(state.progressFraction == 1)

        state.renderModeOverride = .webView
        #expect(!state.showsProgressBar)
    }

    @MainActor
    @Test
    func loadedReaderConsumesProgressReportsAndDebouncesSaves() async {
        let itemID = UUID()
        let item = SavedItem(title: "Read", content: "Body", id: itemID, progressUnitCount: 20)
        let document = ReaderDocument(title: "Read", blocks: [.paragraph([.text("Body")])])
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let saved = LockIsolated<[Int]>([])
        let clock = TestClock()

        let store = TestStore(initialState: ReaderFeature.State(item: item)) {
            ReaderFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.readerProgressClient = ReaderProgressClient(
                progressUpdates: { stream },
                topBlockIndex: { nil }
            )
            $0.stowerRepository.loadReaderDocument = { _ in document }
            $0.stowerRepository.loadSourceHTML = { _ in nil }
            $0.stowerRepository.saveReadingProgress = { _, index in
                saved.withValue { $0.append(index) }
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.load)
        await store.receive(\.loaded)

        continuation.yield(3)
        await store.receive(.scrollProgressChanged(3)) {
            $0.currentBlockIndex = 3
            $0.item?.lastReadBlockIndex = 3
        }
        continuation.yield(7)
        await store.receive(.scrollProgressChanged(7)) {
            $0.currentBlockIndex = 7
            $0.item?.lastReadBlockIndex = 7
        }

        // Only the latest position is written, one second after scrolling stops.
        await clock.advance(by: .seconds(1))
        await store.receive(.saveReadingProgress(7))
        await store.finish(timeout: .seconds(1))
        #expect(saved.value == [7])

        continuation.finish()
    }
}
