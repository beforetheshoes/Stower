import ComposableArchitecture
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@MainActor
@Suite
struct PickedFileReducerTests {
    private struct Unreadable: Error, LocalizedError {
        var errorDescription: String? { "permission denied" }
    }

    private func makeStore(
        _ prepare: (inout DependencyValues) -> Void
    ) -> TestStoreOf<LibraryFeature> {
        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        } withDependencies: {
            prepare(&$0)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    @Test(arguments: [LibraryImportPicker.pdf, .epub, .website])
    func aPickedFileIsStagedAndHandedToItsImporter(kind: LibraryImportPicker) async {
        let picked = URL(fileURLWithPath: "/picked/Report.bin")
        let staged = URL(fileURLWithPath: "/scratch/1/Report.bin")
        let store = makeStore {
            $0.pickedFileClient.stage = { url in
                #expect(url == picked)
                return staged
            }
        }

        await store.send(.filePicked(kind, picked))
        switch kind {
        case .pdf:
            await store.receive(.importPDFSelected(staged))
        case .epub:
            await store.receive(.importEPUBSelected(staged))
        case .website:
            await store.receive(.importWebsiteSelected(staged))
        case .text:
            Issue.record("not a staged kind")
        }
    }

    @Test
    func aFileThatCannotBeCopiedIsReportedByKind() async {
        let store = makeStore {
            $0.pickedFileClient.stage = { _ in throw Unreadable() }
        }

        await store.send(.filePicked(.pdf, URL(fileURLWithPath: "/picked/a.pdf")))
        await store.receive(.saveURLFailed("Couldn't read PDF: permission denied"))

        await store.send(.filePicked(.website, URL(fileURLWithPath: "/picked/site.zip")))
        await store.receive(.saveURLFailed("Couldn't read zip: permission denied"))
    }

    @Test
    func aPickedMarkdownFileIsReadWithItsNameAsTheTitleHint() async {
        let store = makeStore {
            $0.pickedFileClient.readText = { _ in "# Heading\n\nBody" }
        }

        await store.send(.filePicked(.text, URL(fileURLWithPath: "/picked/Meeting Notes.md")))
        await store.receive(\.importTextResolved)
    }

    @Test
    func anUnsupportedTextFileIsRefusedWithoutBeingRead() async {
        let store = makeStore { _ in }

        await store.send(.filePicked(.text, URL(fileURLWithPath: "/picked/archive.bin")))
        await store.receive(.saveURLFailed("Unsupported text file type."))
    }

    @Test
    func aPickerFailureIsReportedByKind() async {
        let store = makeStore { _ in }

        await store.send(.filePickFailed(.epub, "The file is in iCloud and has not downloaded."))
        await store.receive(.saveURLFailed("EPUB import failed: The file is in iCloud and has not downloaded."))
    }
}

@MainActor
@Suite
struct LibraryCommandTests {
    private func makeStore(_ state: LibraryFeature.State = .init()) -> TestStoreOf<LibraryFeature> {
        let store = TestStore(initialState: state) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.deleteItem = { _ in }
            $0.stowerRepository.enqueueIngestionJob = { _, _ in }
            $0.pickedFileClient.stage = { $0 }
            $0.pickedFileClient.readText = { _ in "text" }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    @Test
    func droppedLinksAreSavedAndTheFirstDroppedFileStartsImporting() async throws {
        let store = makeStore()
        let link = try #require(URL(string: "https://example.com/post"))
        let pdf = URL(fileURLWithPath: "/staged/1/Paper.pdf")
        let book = URL(fileURLWithPath: "/staged/2/Novel.epub")

        await store.send(.itemsDropped([.link(link), .file(.pdf, pdf), .file(.epub, book)])) {
            // One import at a time: the book waits for the PDF.
            $0.isSaving = true
            $0.queuedFileImports = [LibraryFeature.QueuedFileImport(kind: .epub, stagedURL: book)]
        }
        await store.receive(.saveExternalURL(link))
        await store.receive(.importPDFSelected(pdf))
    }

    @Test
    func theNextDroppedFileStartsWhenTheCurrentOneFinishes() async {
        let book = URL(fileURLWithPath: "/staged/2/Novel.epub")
        var state = LibraryFeature.State()
        state.isSaving = true
        state.queuedFileImports = [LibraryFeature.QueuedFileImport(kind: .epub, stagedURL: book)]
        let store = makeStore(state)

        await store.send(.saveURLFinished(SavedItem(title: "Paper", content: "Body"))) {
            $0.queuedFileImports = []
        }
        await store.receive(.importEPUBSelected(book))
    }

    @Test
    func aFailureAmongDroppedFilesIsStillShownAfterTheRestFinish() async {
        let book = URL(fileURLWithPath: "/staged/2/Novel.epub")
        var state = LibraryFeature.State()
        state.isSaving = true
        state.queuedFileImports = [LibraryFeature.QueuedFileImport(kind: .epub, stagedURL: book)]
        let store = makeStore(state)

        await store.send(.saveURLFailed("Couldn't read PDF: damaged")) {
            $0.queuedImportFailure = "Couldn't read PDF: damaged"
        }
        await store.receive(.importEPUBSelected(book))

        // The book imports; its start cleared the message. It comes back.
        await store.send(.saveURLFinished(SavedItem(title: "Novel", content: "Body")))
        #expect(store.state.errorMessage == "Couldn't read PDF: damaged")
        #expect(store.state.queuedImportFailure == nil)
        #expect(!store.state.isSaving)
    }

    @Test
    func droppedFilesThatCannotBeImportedAreRefusedByName() async {
        let store = makeStore()

        await store.send(.itemsDropped([.unsupported("photo.heic"), .unreadable(.pdf, "permission denied")]))
        await store.receive(.saveURLFailed("Stower can't import “photo.heic”."))
        await store.receive(.saveURLFailed("Couldn't read PDF: permission denied"))
    }

    @Test
    func anEmptyTextFileFailsThroughTheSamePathAsAnyOther() async {
        let store = makeStore()

        await store.send(.importTextResolved("  \n", "Notes", .auto))
        await store.receive(.saveURLFailed("The selected file is empty."))
    }

    @Test
    func droppedFileKindsAreReadFromTheExtension() {
        #expect(LibraryImportPicker(droppedFile: URL(fileURLWithPath: "/a/b.pdf")) == .pdf)
        #expect(LibraryImportPicker(droppedFile: URL(fileURLWithPath: "/a/b.EPUB")) == .epub)
        #expect(LibraryImportPicker(droppedFile: URL(fileURLWithPath: "/a/site.zip")) == .website)
        #expect(LibraryImportPicker(droppedFile: URL(fileURLWithPath: "/a/b.txt")) == .text)
        #expect(LibraryImportPicker(droppedFile: URL(fileURLWithPath: "/a/b.markdown")) == .text)
        #expect(LibraryImportPicker(droppedFile: URL(fileURLWithPath: "/a/b")) == nil)
    }

    @Test
    func theDeleteKeyTrashesTheSelectedItem() async {
        let id = UUID(1)
        var state = LibraryFeature.State()
        state.openItemID = id
        let store = makeStore(state)

        await store.send(.deleteSelectedItemCommand)
        await store.receive(.deleteItem(id))
    }

    @Test
    func theDeleteKeyInRecentlyDeletedAsksBeforeDeletingForever() async {
        let id = UUID(1)
        var state = LibraryFeature.State()
        state.openItemID = id
        state.filter = .recentlyDeleted
        let store = makeStore(state)

        await store.send(.deleteSelectedItemCommand)
        await store.receive(.permanentlyDeleteTapped(id))
        #expect(store.state.deleteConfirmation != nil)
    }

    @Test
    func theDeleteKeyWithNothingSelectedDoesNothing() async {
        let store = makeStore()
        store.exhaustivity = .on

        await store.send(.deleteSelectedItemCommand)
    }

    #if os(macOS)
    @Test
    func newLinkMovesFocusToTheComposerOnTheMac() async {
        let store = makeStore()

        await store.send(.newURLCommand) {
            $0.composerFocusRequest = 1
        }
        #expect(!store.state.isAddURLPresented)
    }
    #endif
}

@Suite
struct PickedFileClientTests {
    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func stagingCopiesTheFileUnderItsOwnName() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let picked = scratch.appendingPathComponent("Annual Report.pdf")
        try Data("pdf".utf8).write(to: picked)

        let staged = try withDependencies {
            $0.uuid = .incrementing
        } operation: {
            try PickedFileClient.liveValue.stage(picked)
        }
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }

        #expect(staged != picked)
        #expect(staged.lastPathComponent == "Annual Report.pdf")
        #expect(try Data(contentsOf: staged) == Data("pdf".utf8))
        #expect(FileManager.default.fileExists(atPath: picked.path))
    }

    @Test
    func stagingAMissingFileThrows() throws {
        #expect(throws: (any Error).self) {
            try withDependencies {
                $0.uuid = .incrementing
            } operation: {
                try PickedFileClient.liveValue.stage(URL(fileURLWithPath: "/nonexistent/file.pdf"))
            }
        }
    }

    @Test
    func textIsDecodedFromUTF8AndUTF16() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let utf8 = scratch.appendingPathComponent("a.txt")
        let utf16 = scratch.appendingPathComponent("b.txt")
        try Data("café".utf8).write(to: utf8)
        try #require("café".data(using: .utf16)).write(to: utf16)

        #expect(try PickedFileClient.liveValue.readText(utf8) == "café")
        #expect(try PickedFileClient.liveValue.readText(utf16) == "café")
    }
}
