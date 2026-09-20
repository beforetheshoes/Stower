import Foundation
import UniformTypeIdentifiers

/// A file another app handed to Stower ("Open in Stower"), copied somewhere
/// the importers can read it for as long as they need.
public struct IncomingFile: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case epub
        case pdf
    }

    public var kind: Kind
    /// A scratch copy inside a directory of its own. The importers delete
    /// that directory when they finish.
    public var url: URL

    public enum StagingError: Error, Equatable, LocalizedError {
        case unsupportedType(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedType(let name):
                "Stower can't open \"\(name)\". It imports EPUB and PDF files."
            }
        }
    }

    /// Which importer handles `url`, judged by its extension.
    static func kind(of url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .epub) {
            return .epub
        }
        if type.conforms(to: .pdf) {
            return .pdf
        }
        return nil
    }

    /// Copies an opened file into a scratch directory, keeping its name (the
    /// importers fall back to the filename for a title). Files are opened in
    /// place, so the original is read under its security scope and left
    /// alone; only a copy the system dropped in the app's `Inbox` (AirDrop,
    /// Mail attachments) is removed once staged.
    public static func stage(_ source: URL, scratchRoot: URL = FileManager.default.temporaryDirectory) throws -> Self {
        guard let kind = kind(of: source) else {
            throw StagingError.unsupportedType(source.lastPathComponent)
        }
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed { source.stopAccessingSecurityScopedResource() }
        }

        let scratchDir = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        let scratch = scratchDir.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratchDir)
            throw error
        }
        if source.deletingLastPathComponent().lastPathComponent == "Inbox" {
            try? FileManager.default.removeItem(at: source)
        }
        return Self(kind: kind, url: scratch)
    }
}
