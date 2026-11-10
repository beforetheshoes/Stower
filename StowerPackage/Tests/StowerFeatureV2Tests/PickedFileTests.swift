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
