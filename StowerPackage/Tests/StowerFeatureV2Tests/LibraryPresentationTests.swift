import ComposableArchitecture
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

/// The library's sheets and pickers are reducer state. Each can be opened
/// from a toolbar menu, so each is presented a turn after it is asked for.
@MainActor
@Suite
struct LibraryPresentationTests {
    private func makeStore(_ state: LibraryFeature.State = .init()) -> TestStoreOf<LibraryFeature> {
        let store = TestStore(initialState: state) {
            LibraryFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    @Test
    func addURLOpensAndClosesWhenTheLinkIsQueued() async throws {
        let store = makeStore()

        await store.send(.addURLButtonTapped)
        #expect(!store.state.isAddURLPresented)
        await store.receive(.addURLPresentationChanged(true)) {
            $0.isAddURLPresented = true
        }

        await store.send(.urlQueued(try #require(URL(string: "https://example.com")))) {
            $0.isAddURLPresented = false
        }
    }

    @Test
    func reopeningAddURLAfterAFailureStartsClean() async {
        var state = LibraryFeature.State()
        state.saveState = .failed
        state.sourceURL = "https://example.com/broken"
        state.errorMessage = "Could not load the page."
        let store = makeStore(state)

        await store.send(.addURLButtonTapped)
        await store.receive(.sourceURLChanged(""))
        await store.receive(.addURLPresentationChanged(true))

        #expect(store.state.sourceURL.isEmpty)
        #expect(store.state.isAddURLPresented)
    }

    @Test
    func dismissingAddURLByHandIsRecorded() async {
        var state = LibraryFeature.State()
        state.isAddURLPresented = true
        let store = makeStore(state)

        await store.send(.addURLPresentationChanged(false)) {
            $0.isAddURLPresented = false
        }
    }

    @Test
    func textImportShowsOnceItHasADraftAndClearsItWhenDismissed() async {
        let store = makeStore()

        await store.send(.addTextTapped)
        #expect(store.state.textImportDraft != nil)
        #expect(!store.state.showsTextImportSheet)
        await store.receive(.textImportPresentationChanged(true))
        #expect(store.state.showsTextImportSheet)

        // Swiping the sheet away arrives as the binding being set to false.
        await store.send(.textImportPresentationChanged(false))
        await store.receive(.textImportDismissed)
        #expect(store.state.textImportDraft == nil)
        #expect(!store.state.isTextImportPresented)
        #expect(!store.state.showsTextImportSheet)
    }

    @Test
    func aFinishedTextSaveClosesItsSheet() async {
        var state = LibraryFeature.State()
        state.textImportDraft = LibraryFeature.TextImportDraft()
        state.isTextImportPresented = true
        let store = makeStore(state)

        await store.send(.saveURLFinished(SavedItem(title: "Note", content: "Body")))

        #expect(!store.state.showsTextImportSheet)
        #expect(!store.state.isTextImportPresented)
    }

    @Test
    func aDocumentPickerIsPresentedAndCleared() async {
        let store = makeStore()

        await store.send(.importPickerRequested(.pdf))
        #expect(store.state.importPicker == nil)
        await store.receive(.importPickerChanged(.pdf)) {
            $0.importPicker = .pdf
        }

        await store.send(.importPickerChanged(nil)) {
            $0.importPicker = nil
        }
    }

    @Test
    func aFileImportWithNoSheetUpIsReportedAsImporting() {
        var state = LibraryFeature.State()
        #expect(!state.isImportingFile)

        state.isSaving = true
        #expect(state.isImportingFile)

        // A save running behind its own sheet shows its progress there.
        state.isAddURLPresented = true
        #expect(!state.isImportingFile)
        state.isAddURLPresented = false
        state.isTextImportPresented = true
        state.textImportDraft = LibraryFeature.TextImportDraft()
        #expect(!state.isImportingFile)
    }
}
