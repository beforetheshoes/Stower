import Dependencies
import DependenciesMacros
import Foundation

/// Reads a file the user picked from a document picker or open panel.
///
/// A picked URL is security-scoped, and a temporary one at that: access has
/// to be opened around every read, and the file should be copied somewhere
/// plain before anything long-lived holds on to it. That used to be done in
/// the view, four times over.
@DependencyClient
public struct PickedFileClient: Sendable {
    /// Copies the picked file into a scratch directory of its own, keeping
    /// its name, and returns the copy.
    ///
    /// The name matters: the PDF and EPUB ingesters fall back to it for the
    /// title, and a copy named after a UUID would title the item with one.
    public var stage: @Sendable (_ pickedURL: URL) throws -> URL
    /// Reads the picked file as text, trying the encodings a text export is
    /// likely to be in.
    public var readText: @Sendable (_ pickedURL: URL) throws -> String
}

extension PickedFileClient: DependencyKey {
    public static var testValue: PickedFileClient {
        PickedFileClient()
    }

    public static var liveValue: PickedFileClient {
        PickedFileClient(
            stage: { pickedURL in
                try withSecurityScope(pickedURL) {
                    @Dependency(\.uuid)
                    var uuid
                    let scratchDirectory = FileManager.default.temporaryDirectory
                        .appendingPathComponent(uuid().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: scratchDirectory,
                        withIntermediateDirectories: true
                    )
                    let scratch = scratchDirectory.appendingPathComponent(pickedURL.lastPathComponent)
                    try FileManager.default.copyItem(at: pickedURL, to: scratch)
                    return scratch
                }
            },
            readText: { pickedURL in
                try withSecurityScope(pickedURL) {
                    decodeImportedText(try Data(contentsOf: pickedURL))
                }
            }
        )
    }

    private static func withSecurityScope<Value>(_ url: URL, _ work: () throws -> Value) rethrows -> Value {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        return try work()
    }
}

extension DependencyValues {
    public var pickedFileClient: PickedFileClient {
        get { self[PickedFileClient.self] }
        set { self[PickedFileClient.self] = newValue }
    }
}

/// Decodes text of unknown encoding: UTF-8 first, then the UTF-16 forms.
func decodeImportedText(_ data: Data) -> String {
    for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian] {
        if let text = String(data: data, encoding: encoding) {
            return text
        }
    }
    return String(bytes: data, encoding: .utf8) ?? ""
}
