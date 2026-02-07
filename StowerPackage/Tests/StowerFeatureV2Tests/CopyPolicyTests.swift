import Foundation
import Testing

@Suite
struct CopyPolicyTests {
    @Test
    func bannedTermsDoNotAppearInFeatureSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/StowerFeatureV2")

        let bannedTerms = ["unread", "backlog", "behind", "overdue", "catching up"]
        let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }

        for relativePath in files {
            let url = sources.appendingPathComponent(relativePath)
            let contents = try String(contentsOf: url, encoding: .utf8)
            let lowered = contents.lowercased()
            for term in bannedTerms {
                #expect(!lowered.contains(term), "Found banned term '\(term)' in \(relativePath)")
            }
        }
    }
}
