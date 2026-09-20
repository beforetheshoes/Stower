import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@MainActor
@Suite(.dependencies { try $0.bootstrapStowerDatabase(enableSync: false) })
struct LibraryEPUBImportTests {
    @Test
    func pickedEPUBIsImportedOpenedAndItsScratchCopyRemoved() async throws {
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let picked = scratchDir.appendingPathComponent("Novel.epub")
        try Data("epub".utf8).write(to: picked)

        let book = SavedItem(title: "Novel", content: "Body", processingState: .ready)
        defer { AssetArchiver.deleteArchive(for: book.id) }

        let uploads = LockIsolated<[(IngestionJob.Kind, String)]>([])

        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        } withDependencies: {
            $0.epubIngestionClient.ingest = { _ in .sharedText("Body") }
            $0.stowerRepository.createItemFromIngestion = { _ in book }
            $0.stowerRepository.enqueueIngestionJob = { kind, payload in
                uploads.withValue { $0.append((kind, payload)) }
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.importEPUBSelected(picked)) {
            $0.isSaving = true
            $0.saveState = .extracting
        }
        await store.receive(.saveURLFinished(book)) {
            $0.isSaving = false
            $0.saveState = .ready
        }
        await store.receive(.openItem(book))
        await store.finish()

        #expect(try Data(contentsOf: EPUBBookArchiver.bookURL(for: book.id)) == Data("epub".utf8))
        #expect(!FileManager.default.fileExists(atPath: scratchDir.path))
        // The original file is queued for upload so other devices get it.
        let upload = try #require(uploads.value.first)
        #expect(upload.0 == .uploadAsset)
        let payload = try AssetJobPayload.decoded(from: upload.1)
        #expect(payload == AssetJobPayload(itemID: book.id, kind: .epub, originalFilename: "Novel.epub"))
    }

    @Test
    func importFailureSurfacesTheReason() async throws {
        let picked = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Locked.epub")

        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        } withDependencies: {
            $0.epubIngestionClient.ingest = { _ in throw EPUBIngestionError.protectedContent }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.importEPUBSelected(picked))
        await store.receive(.saveURLFailed(EPUBIngestionError.protectedContent.localizedDescription)) {
            $0.isSaving = false
            $0.saveState = .failed
            $0.errorMessage = EPUBIngestionError.protectedContent.localizedDescription
        }
    }

    @Test
    func importedBooksAreNotEditableAsText() {
        let note = SavedItem(title: "Note", content: "Body", renderFormat: .structuredV1)
        let book = SavedItem(
            title: "Book",
            content: "Body",
            canonicalURL: SavedItem.importedBookURLPrefix + "abc",
            renderFormat: .structuredV1
        )

        #expect(ReaderFeature.State(item: note, appearance: ReaderAppearanceSettings()).canEditTextSource)
        #expect(!ReaderFeature.State(item: book, appearance: ReaderAppearanceSettings()).canEditTextSource)
    }
}
