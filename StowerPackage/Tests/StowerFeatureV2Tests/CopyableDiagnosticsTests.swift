import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

#if os(macOS)
import AppKit
#endif

/// Every error and diagnostic in the app used to be a plain `Text` — not
/// selectable, sometimes truncated, and impossible to get out of the app except
/// by retyping it from a screenshot. These tests pin the part of that fix that
/// is mechanically checkable: what actually reaches the clipboard.
@MainActor
@Suite
struct CopyableDiagnosticsTests {
    // MARK: - Clipboard

    #if os(macOS)
    @Test
    func clipboardRoundTrips() {
        // Only assertable on macOS; UIPasteboard is not reliably readable from
        // a unit-test process.
        let value = "CKError Code=2 \"Failed to send changes\""
        ClipboardSupport.copy(value)
        #expect(NSPasteboard.general.string(forType: .string) == value)
    }
    #endif

    // MARK: - Copy payload is never the truncated string

    @Test
    func copyableTextCopiesTheFullStringWhenDisplayIsTruncated() {
        let full = String(repeating: "a very long diagnostic line. ", count: 40)
        let view = CopyableText(text: full, lineLimit: 2)
        #expect(view.payload == full)
    }

    @Test
    func copyableTextPrefersAnExplicitCopyPayload() {
        let view = CopyableText(text: "short label", copyText: "the whole story")
        #expect(view.payload == "the whole story")
    }

    // MARK: - Failed-import report

    private func failure(_ payload: String, _ reason: String?) -> FailedImport {
        FailedImport(
            job: IngestionJob(
                kind: .url,
                payload: payload,
                id: UUID(),
                createdAt: Date(timeIntervalSince1970: 0),
                status: .failed,
                claimedAt: nil,
                attemptCount: 3,
                lastError: reason
            )
        )
    }

    @Test
    func failedImportKeepsTheUntruncatedPayload() {
        // `label` is elided for the banner with a literal ellipsis, so it
        // cannot be used to reconstruct what was being imported.
        let long = "https://example.com/" + String(repeating: "segment/", count: 20) + "end"
        let entry = failure(long, "The request timed out.")
        #expect(entry.label.contains("…"))
        #expect(entry.rawPayload == long)
    }

    @Test
    func reportIncludesEveryFailureNotJustTheFirst() {
        // The banner shows one failure and says "and N more"; copying has to
        // produce all of them or it is no more useful than the screen.
        let imports = [
            failure("https://example.com/one", "Timed out."),
            failure("https://example.com/two", "Blocked by a bot check."),
            failure("https://example.com/three", nil),
        ]
        let report = FailedImport.diagnosticReport(from: imports)

        #expect(report.contains("3 Stower imports failed"))
        #expect(report.contains("https://example.com/one"))
        #expect(report.contains("https://example.com/two"))
        #expect(report.contains("https://example.com/three"))
        #expect(report.contains("Blocked by a bot check."))
        #expect(report.contains("No reason recorded."))
        #expect(!report.contains("…"))
    }

    @Test
    func emptyReportForNoFailures() {
        #expect(FailedImport.diagnosticReport(from: []).isEmpty)
    }

    // MARK: - Sync diagnostics report

    @Test
    func syncReportCarriesFullURLsAndEveryCount() {
        let longURL = "https://example.com/" + String(repeating: "path/", count: 30) + "article"
        let diagnostics = SyncDiagnostics(
            syncedItemsCount: 12,
            pendingChangesCount: 3,
            metadataCount: 7,
            syncedTagsCount: 4,
            syncedItemTagsCount: 5,
            sampleItems: [SyncItemSummary(id: UUID(), title: "An article", sourceURL: longURL)]
        )
        let status = CloudSyncStatus(state: .error("Cannot create new type in production schema"))
        let report = SyncDiagnosticsReport.text(diagnostics: diagnostics, status: status)

        #expect(report.contains(longURL))
        #expect(report.contains("Synced rows: 12"))
        #expect(report.contains("Synced tags: 4"))
        #expect(report.contains("Synced item-tag links: 5"))
        #expect(report.contains("Pending changes: 3"))
        #expect(report.contains("Metadata rows: 7"))
        #expect(report.contains("Cannot create new type in production schema"))
    }

    @Test
    func syncReportHandlesAHealthyStateWithoutDetail() {
        let report = SyncDiagnosticsReport.text(
            diagnostics: SyncDiagnostics(syncedItemsCount: 0, pendingChangesCount: 0, metadataCount: 0),
            status: CloudSyncStatus(state: .available)
        )
        #expect(report.contains("State: On"))
        #expect(!report.contains("Detail:"))
        #expect(report.contains("Last success: never"))
    }
}

/// The previous clipboard helper was private to one screen, which is why no
/// error message in the app could be copied. This keeps it consolidated.
@Suite
struct ClipboardConsolidationTests {
    @Test
    func pasteboardIsUsedOnlyInClipboardSupport() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StowerFeatureV2")

        let files = try FileManager.default
            .subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }

        for relativePath in files where relativePath != "Support/ClipboardSupport.swift" {
            let contents = try String(
                contentsOf: sources.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(
                !contents.contains("UIPasteboard") && !contents.contains("NSPasteboard"),
                "Pasteboard use belongs in ClipboardSupport, found in \(relativePath)"
            )
        }
    }
}
