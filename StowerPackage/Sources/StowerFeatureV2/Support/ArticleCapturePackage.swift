import CryptoKit
import Foundation
import StowerData
import ZIPFoundation

struct ArticleCaptureMetadata: Codable, Equatable, Sendable {
    let captureID: UUID
    let version: Int
    let sourceURL: URL
    let capturedAt: Date
    let completeness: WebCaptureCompleteness
    let warnings: [String]
}

enum ArticleCapturePackage {
    static let captureVersion = 1
    static let chunkByteLimit = 20 * 1_048_576
    static let packageByteLimit = 200 * 1_048_576

    static let metadataFilename = "manifest.json"
    static let readerArchiveFilename = "reader.webarchive"
    static let originalArchiveFilename = "original.webarchive"
    static let documentFilename = "document.json"
    static let plainTextFilename = "plain.txt"
    static let installedPackageFilename = "capture.zip"

    static func stage(
        captureID: UUID,
        sourceURL: URL,
        readerArchive: Data,
        originalArchive: Data,
        document: ReaderDocument,
        plainText: String,
        completeness: WebCaptureCompleteness,
        warnings: [String]
    ) throws -> WebCaptureArtifact {
        let fileManager = FileManager.default
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("StowerCapture-\(captureID.uuidString)", isDirectory: true)
        let packageDirectory = stagingRoot.appendingPathComponent("capture", isDirectory: true)
        let zipURL = stagingRoot.appendingPathComponent("capture.zip")
        try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: true)

        let metadata = ArticleCaptureMetadata(
            captureID: captureID,
            version: captureVersion,
            sourceURL: sourceURL,
            capturedAt: .now,
            completeness: completeness,
            warnings: warnings
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(
            to: packageDirectory.appendingPathComponent(metadataFilename),
            options: .atomic
        )
        try readerArchive.write(
            to: packageDirectory.appendingPathComponent(readerArchiveFilename),
            options: .atomic
        )
        try originalArchive.write(
            to: packageDirectory.appendingPathComponent(originalArchiveFilename),
            options: .atomic
        )
        try encoder.encode(document).write(
            to: packageDirectory.appendingPathComponent(documentFilename),
            options: .atomic
        )
        try Data(plainText.utf8).write(
            to: packageDirectory.appendingPathComponent(plainTextFilename),
            options: .atomic
        )
        try fileManager.zipItem(at: packageDirectory, to: zipURL, shouldKeepParent: false)

        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        guard data.count <= packageByteLimit else {
            throw ArticleCapturePackageError.packageTooLarge(data.count)
        }
        return WebCaptureArtifact(
            captureID: captureID,
            version: captureVersion,
            stagedPackageURL: zipURL,
            sha256: sha256(data),
            byteCount: data.count,
            completeness: completeness,
            warnings: warnings
        )
    }

    static func install(_ artifact: WebCaptureArtifact, for itemID: UUID) throws {
        let data = try Data(contentsOf: artifact.stagedPackageURL, options: .mappedIfSafe)
        try install(
            packageData: data,
            expectedHash: artifact.sha256,
            expectedCaptureID: artifact.captureID,
            for: itemID
        )
    }

    static func install(
        packageData: Data,
        expectedHash: String,
        expectedCaptureID: UUID,
        for itemID: UUID
    ) throws {
        guard packageData.count <= packageByteLimit else {
            throw ArticleCapturePackageError.packageTooLarge(packageData.count)
        }
        guard sha256(packageData) == expectedHash else {
            throw ArticleCapturePackageError.aggregateHashMismatch
        }

        let fileManager = FileManager.default
        let itemDirectory = AssetArchiver.archiveDirectory(for: itemID)
        let temporaryDirectory = itemDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".capture-install-\(UUID().uuidString)", isDirectory: true)
        let zipURL = temporaryDirectory.appendingPathComponent(installedPackageFilename)
        let extractedDirectory = temporaryDirectory.appendingPathComponent("extracted", isDirectory: true)
        let destination = captureDirectory(for: itemID)
        let backup = itemDirectory.appendingPathComponent(".capture-backup-\(UUID().uuidString)")

        try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        try packageData.write(to: zipURL, options: .atomic)
        try fileManager.unzipItem(at: zipURL, to: extractedDirectory)

        let required = [metadataFilename, readerArchiveFilename, originalArchiveFilename, documentFilename, plainTextFilename]
        guard required.allSatisfy({ fileManager.fileExists(atPath: extractedDirectory.appendingPathComponent($0).path) }) else {
            throw ArticleCapturePackageError.missingRequiredFile
        }
        let metadataData = try Data(contentsOf: extractedDirectory.appendingPathComponent(metadataFilename))
        let metadata = try JSONDecoder().decode(ArticleCaptureMetadata.self, from: metadataData)
        guard metadata.captureID == expectedCaptureID, metadata.version == captureVersion else {
            throw ArticleCapturePackageError.wrongCapture
        }
        try packageData.write(
            to: extractedDirectory.appendingPathComponent(installedPackageFilename),
            options: .atomic
        )

        try fileManager.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: extractedDirectory, to: destination)
            try? fileManager.removeItem(at: backup)
        } catch {
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    static func makeChunks(from artifact: WebCaptureArtifact, itemID: UUID) throws -> (WebCaptureManifest, [WebCaptureChunk]) {
        let packageData = try Data(contentsOf: artifact.stagedPackageURL, options: .mappedIfSafe)
        guard packageData.count == artifact.byteCount, sha256(packageData) == artifact.sha256 else {
            throw ArticleCapturePackageError.aggregateHashMismatch
        }
        let chunks = stride(from: 0, to: packageData.count, by: chunkByteLimit).enumerated().map { sequence, offset in
            let end = min(offset + chunkByteLimit, packageData.count)
            let data = packageData.subdata(in: offset..<end)
            return WebCaptureChunk(sequence: sequence, data: data, sha256: sha256(data))
        }
        return (
            WebCaptureManifest(
                itemID: itemID,
                captureID: artifact.captureID,
                version: artifact.version,
                sha256: artifact.sha256,
                byteCount: artifact.byteCount,
                chunkCount: chunks.count
            ),
            chunks
        )
    }

    static func reconstruct(_ capture: SyncedWebCapture) throws -> Data {
        let ordered = capture.chunks.sorted { $0.sequence < $1.sequence }
        guard ordered.count == capture.manifest.chunkCount,
              ordered.map(\.sequence) == Array(0..<capture.manifest.chunkCount)
        else { throw ArticleCapturePackageError.incompleteChunkSet }
        for chunk in ordered {
            guard chunk.data.count <= chunkByteLimit, sha256(chunk.data) == chunk.sha256 else {
                throw ArticleCapturePackageError.chunkHashMismatch(chunk.sequence)
            }
        }
        let packageData = ordered.reduce(into: Data()) { $0.append($1.data) }
        guard packageData.count == capture.manifest.byteCount,
              sha256(packageData) == capture.manifest.sha256
        else { throw ArticleCapturePackageError.aggregateHashMismatch }
        return packageData
    }

    static func captureDirectory(for itemID: UUID) -> URL {
        AssetArchiver.archiveDirectory(for: itemID)
            .appendingPathComponent("web-capture-v1", isDirectory: true)
    }

    static func archiveURL(for itemID: UUID, original: Bool) -> URL? {
        let url = captureDirectory(for: itemID).appendingPathComponent(
            original ? originalArchiveFilename : readerArchiveFilename
        )
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func metadata(for itemID: UUID) -> ArticleCaptureMetadata? {
        let url = captureDirectory(for: itemID).appendingPathComponent(metadataFilename)
        return try? JSONDecoder().decode(ArticleCaptureMetadata.self, from: Data(contentsOf: url))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ArticleCapturePackageError: Error, LocalizedError, Equatable {
    case packageTooLarge(Int)
    case incompleteChunkSet
    case chunkHashMismatch(Int)
    case aggregateHashMismatch
    case missingRequiredFile
    case wrongCapture

    var errorDescription: String? {
        switch self {
        case .packageTooLarge:
            return "The compressed article capture exceeds the 200 MiB limit."
        case .incompleteChunkSet:
            return "The synced article capture is still missing one or more chunks."
        case .chunkHashMismatch(let sequence):
            return "Article capture chunk \(sequence) failed its integrity check."
        case .aggregateHashMismatch:
            return "The article capture failed its integrity check."
        case .missingRequiredFile:
            return "The article capture package is missing a required file."
        case .wrongCapture:
            return "The article capture package does not match its manifest."
        }
    }
}
