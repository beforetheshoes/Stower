import Foundation
@testable import StowerFeature
import Testing

@Suite(.serialized)
struct ArticleCapturePackageTests {
    @Test
    func packageRoundTripInstallsBothArchivesAndIndexes() throws {
        let itemID = UUID()
        let captureID = UUID()
        defer { AssetArchiver.deleteArchive(for: itemID) }
        let artifact = try ArticleCapturePackage.stage(
            captureID: captureID,
            sourceURL: URL(string: "https://example.com/story")!,
            readerArchive: Data("reader archive".utf8),
            originalArchive: Data("original archive".utf8),
            document: ReaderDocument(title: "Story", blocks: [.paragraph([.text("Body")])]),
            plainText: "Body",
            completeness: .partial,
            warnings: ["One image was unavailable."]
        )
        defer { try? FileManager.default.removeItem(at: artifact.stagedPackageURL.deletingLastPathComponent()) }

        try ArticleCapturePackage.install(artifact, for: itemID)

        let readerURL = try #require(ArticleCapturePackage.archiveURL(for: itemID, original: false))
        let originalURL = try #require(ArticleCapturePackage.archiveURL(for: itemID, original: true))
        #expect(try Data(contentsOf: readerURL) == Data("reader archive".utf8))
        #expect(try Data(contentsOf: originalURL) == Data("original archive".utf8))
        #expect(ArticleCapturePackage.metadata(for: itemID)?.completeness == .partial)
    }

    @Test
    func chunksAtTwentyMiBBoundaryAndReconstructsInSequence() throws {
        let size = ArticleCapturePackage.chunkByteLimit + 17
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-chunk-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("capture.zip")
        try data.write(to: packageURL)
        let artifact = WebCaptureArtifact(
            captureID: UUID(),
            stagedPackageURL: packageURL,
            sha256: ArticleCapturePackage.sha256(data),
            byteCount: data.count,
            completeness: .complete
        )

        let (manifest, chunks) = try ArticleCapturePackage.makeChunks(from: artifact, itemID: UUID())
        #expect(chunks.count == 2)
        #expect(chunks[0].data.count == ArticleCapturePackage.chunkByteLimit)
        #expect(chunks[1].data.count == 17)
        let rebuilt = try ArticleCapturePackage.reconstruct(
            SyncedWebCapture(manifest: manifest, chunks: Array(chunks.reversed()))
        )
        #expect(rebuilt == data)
    }

    @Test
    func rejectsMissingAndCorruptChunks() throws {
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let all = first + second
        let itemID = UUID()
        let captureID = UUID()
        let manifest = WebCaptureManifest(
            itemID: itemID,
            captureID: captureID,
            sha256: ArticleCapturePackage.sha256(all),
            byteCount: all.count,
            chunkCount: 2
        )
        let good = WebCaptureChunk(sequence: 0, data: first, sha256: ArticleCapturePackage.sha256(first))
        #expect(throws: ArticleCapturePackageError.incompleteChunkSet) {
            try ArticleCapturePackage.reconstruct(SyncedWebCapture(manifest: manifest, chunks: [good]))
        }
        let corrupt = WebCaptureChunk(sequence: 1, data: second, sha256: "bad")
        #expect(throws: ArticleCapturePackageError.chunkHashMismatch(1)) {
            try ArticleCapturePackage.reconstruct(SyncedWebCapture(manifest: manifest, chunks: [good, corrupt]))
        }
    }
}
