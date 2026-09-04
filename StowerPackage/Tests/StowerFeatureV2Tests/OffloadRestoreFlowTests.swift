import ComposableArchitecture
import Dependencies
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

/// Reader-side behavior for offloaded items: opening one triggers a restore,
/// success reloads, failure surfaces a retryable message.
@MainActor
@Suite
struct OffloadRestoreFlowTests {
    private static func makePDFItem(id: UUID = UUID()) -> SavedItem {
        SavedItem(title: "Offloaded PDF", content: "extracted text", id: id, renderFormat: .pdf)
    }

    @Test
    func needsOffloadRestore_detectsMissingFiles() {
        // A random-ID PDF item has no document.pdf on disk.
        #expect(ReaderFeature.needsOffloadRestore(Self.makePDFItem()))
        let article = SavedItem(title: "Article", content: "text", renderFormat: .structuredV1)
        #expect(!ReaderFeature.needsOffloadRestore(article))
    }

    @Test
    func openingOffloadedItemWithNoSourcesFailsWithRetryableMessage() async {
        let item = Self.makePDFItem()
        let store = TestStore(
            initialState: ReaderFeature.State(item: item)
        ) {
            ReaderFeature()
        } withDependencies: {
            $0.itemStorageClient = .noop
            $0.cloudAssetClient = .noop
            $0.cloudSyncClient = .noop
            $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off

        await store.send(.restoreOffloadedContent) {
            $0.offloadRestore = .restoring
        }
        await store.receive(\.offloadRestoreFinished) {
            guard case .failed = $0.offloadRestore else {
                Issue.record("Expected failed restore state")
                return
            }
        }
    }

    @Test
    func restoreFinishedWithoutErrorReloads() async {
        let item = Self.makePDFItem()
        let store = TestStore(
            initialState: {
                var state = ReaderFeature.State(item: item)
                state.offloadRestore = .restoring
                state.document = ReaderDocument(title: "Old", blocks: [])
                return state
            }()
        ) {
            ReaderFeature()
        } withDependencies: {
            $0.itemStorageClient = .noop
            $0.cloudSyncClient = .noop
            $0.continuousClock = ImmediateClock()
            $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
        }
        store.exhaustivity = .off

        await store.send(.offloadRestoreFinished(nil)) {
            $0.offloadRestore = .idle
            $0.document = nil
            $0.sourceHTML = nil
        }
        await store.receive(\.load)
        await store.finish()
    }
}
