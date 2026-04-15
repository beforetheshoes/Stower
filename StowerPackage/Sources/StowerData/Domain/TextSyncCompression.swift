import Foundation

/// Compresses and decompresses text for CloudKit sync. CloudKit has a 1 MB
/// per-record limit; long markdown articles can exceed that. Zlib compression
/// + base64 encoding typically achieves 3–5× reduction on text, keeping even
/// very large articles well under the limit.
public enum TextSyncCompression {
    /// Compresses a string with zlib and returns a base64-encoded representation.
    /// Falls back to the original string if compression fails.
    public static func compress(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let data = Data(text.utf8)
        guard let compressed = try? (data as NSData).compressed(using: .zlib) as Data else {
            return text
        }
        return compressed.base64EncodedString()
    }

    /// Decompresses a base64+zlib string back to the original text.
    /// If the input isn't valid base64 or isn't compressed, returns the
    /// input as-is (backward-compatible with uncompressed legacy data).
    public static func decompress(_ stored: String) -> String {
        guard !stored.isEmpty else { return "" }
        guard let data = Data(base64Encoded: stored) else {
            // Not base64 — assume it's uncompressed plain text.
            return stored
        }
        guard let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data,
              let text = String(data: decompressed, encoding: .utf8)
        else {
            // Decompression failed — return the original string (may be
            // uncompressed text that happens to look like valid base64).
            return stored
        }
        return text
    }
}
