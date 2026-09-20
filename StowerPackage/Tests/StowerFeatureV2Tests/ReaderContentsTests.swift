import ComposableArchitecture
import CustomDump
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@MainActor
struct ReaderContentsTests {
    private static let document = ReaderDocument(
        title: "Book",
        blocks: [
            .heading(level: 2, inlines: [.text("One")]),
            .paragraph([.text("Body")]),
            .heading(level: 3, inlines: [.text("One, part "), .emphasis("two")]),
            .heading(level: 2, inlines: [.text("  ")]),
            .heading(level: 2, inlines: [.text("Two")]),
        ]
    )

    @Test
    func entries_listHeadingsWithDepthRelativeToTheShallowestLevel() {
        expectNoDifference(
            ReaderContentsEntry.entries(for: Self.document),
            [
                ReaderContentsEntry(blockIndex: 0, depth: 0, title: "One"),
                ReaderContentsEntry(blockIndex: 2, depth: 1, title: "One, part two"),
                ReaderContentsEntry(blockIndex: 4, depth: 0, title: "Two"),
            ]
        )
    }

    @Test
    func entries_areEmptyForDocumentsWithFewHeadings() {
        let document = ReaderDocument(
            title: "Article",
            blocks: [
                .heading(level: 2, inlines: [.text("Only")]),
                .paragraph([.text("Body")]),
                .heading(level: 2, inlines: [.text("Two")]),
            ]
        )
        #expect(ReaderContentsEntry.entries(for: document).isEmpty)
        #expect(ReaderContentsEntry.entries(for: nil).isEmpty)
    }

    @Test
    func choosingAnEntryDismissesTheSheetAndRequestsAJump() async {
        var state = ReaderFeature.State(
            item: SavedItem(title: "Book", content: "Body"),
            appearance: ReaderAppearanceSettings()
        )
        state.contents = ReaderContentsEntry.entries(for: Self.document)
        let store = TestStore(initialState: state) {
            ReaderFeature()
        }
        let entry = state.contents[2]

        await store.send(.contentsButtonTapped) {
            $0.isContentsPresented = true
        }
        await store.send(.contentsEntryTapped(entry)) {
            $0.isContentsPresented = false
            $0.scrollRequest = ReaderScrollRequest(sequence: 1, blockIndex: 4)
        }
        // Choosing the same row again is a new request, so the page jumps
        // back even though the target is unchanged.
        await store.send(.contentsEntryTapped(entry)) {
            $0.scrollRequest = ReaderScrollRequest(sequence: 2, blockIndex: 4)
        }
        await store.send(.contentsButtonTapped) {
            $0.isContentsPresented = true
        }
        await store.send(.contentsDismissed) {
            $0.isContentsPresented = false
        }
    }
}
