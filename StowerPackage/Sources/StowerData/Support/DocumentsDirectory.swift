import Dependencies
import Foundation

/// The directory Stower keeps its files in: article archives, books, PDFs and
/// downloaded images.
///
/// In the app this is the Documents directory. Everything that touches those
/// files asks for it here rather than going to `FileManager` directly, so
/// tests get a directory of their own. They used to read and write the real
/// container, which made suites interfere with each other — and with an
/// installed copy of the app on the same machine.
private enum DocumentsDirectoryKey: DependencyKey {
    static let liveValue: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)
        .first!

    /// One scratch directory per test process.
    static let testValue: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StowerTests-\(ProcessInfo.processInfo.globallyUniqueString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var previewValue: URL { testValue }
}

extension DependencyValues {
    public var stowerDocumentsDirectory: URL {
        get { self[DocumentsDirectoryKey.self] }
        set { self[DocumentsDirectoryKey.self] = newValue }
    }
}

/// The current documents directory, for static helpers that have no
/// dependency scope of their own.
public func stowerDocumentsDirectory() -> URL {
    @Dependency(\.stowerDocumentsDirectory)
    var directory
    return directory
}
