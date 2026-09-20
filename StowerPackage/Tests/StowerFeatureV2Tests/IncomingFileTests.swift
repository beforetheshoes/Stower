import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

struct IncomingFileTests {
    private func makeDirectory(named name: String = UUID().uuidString) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test(arguments: [
        ("Novel.epub", IncomingFile.Kind.epub),
        ("NOVEL.EPUB", IncomingFile.Kind.epub),
        ("Report.pdf", IncomingFile.Kind.pdf),
    ])
    func kind_isJudgedByExtension(filename: String, expected: IncomingFile.Kind) {
        #expect(IncomingFile.kind(of: URL(fileURLWithPath: "/tmp/\(filename)")) == expected)
    }

    @Test
    func stage_copiesTheFileUnderItsOwnName() throws {
        let sourceDir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDir.deletingLastPathComponent()) }
        let source = sourceDir.appendingPathComponent("My Novel.epub")
        try Data("epub".utf8).write(to: source)

        let staged = try IncomingFile.stage(source)
        defer { try? FileManager.default.removeItem(at: staged.url.deletingLastPathComponent()) }

        #expect(staged.kind == .epub)
        #expect(staged.url.lastPathComponent == "My Novel.epub")
        #expect(try Data(contentsOf: staged.url) == Data("epub".utf8))
        // A file opened from elsewhere on disk is the user's and stays put.
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test
    func stage_removesTheSystemsInboxCopy() throws {
        let inbox = try makeDirectory(named: "Inbox")
        defer { try? FileManager.default.removeItem(at: inbox.deletingLastPathComponent()) }
        let source = inbox.appendingPathComponent("Report.pdf")
        try Data("pdf".utf8).write(to: source)

        let staged = try IncomingFile.stage(source)
        defer { try? FileManager.default.removeItem(at: staged.url.deletingLastPathComponent()) }

        #expect(staged.kind == .pdf)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test
    func stage_rejectsOtherFileTypes() {
        #expect(throws: IncomingFile.StagingError.unsupportedType("notes.docx")) {
            try IncomingFile.stage(URL(fileURLWithPath: "/tmp/notes.docx"))
        }
    }
}

@MainActor
@Suite(.dependencies { try $0.bootstrapStowerDatabase(enableSync: false) })
struct OpenedFileRoutingTests {
    @Test
    func openedEPUBIsHandedToTheBookImporter() async throws {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let source = sourceDir.appendingPathComponent("Novel.epub")
        try Data("epub".utf8).write(to: source)
        let ingested = LockIsolated<[String]>([])

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.epubIngestionClient.ingest = { url in
                ingested.withValue { $0.append(url.lastPathComponent) }
                throw EPUBIngestionError.emptyBook
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.fileOpened(source))
        await store.receive(\.library.importEPUBSelected)
        await store.receive(\.library.saveURLFailed)

        #expect(ingested.value == ["Novel.epub"])
    }

    @Test
    func unsupportedFileReportsWhy() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.fileOpened(URL(fileURLWithPath: "/tmp/notes.docx")))
        await store.receive(
            .library(.saveURLFailed("Stower can't open \"notes.docx\". It imports EPUB and PDF files."))
        ) {
            $0.library.errorMessage = "Stower can't open \"notes.docx\". It imports EPUB and PDF files."
        }
    }
}
