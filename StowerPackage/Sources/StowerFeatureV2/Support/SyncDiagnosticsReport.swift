import Foundation
import StowerData

/// Renders sync state as pasteable text.
///
/// The Sync Diagnostics section shows each figure in its own row and elides the
/// sample items' URLs to one line, which is fine to read and useless to report:
/// there is no way to get any of it out of the app. One button producing this
/// string is worth more than a copy control on every row — and unlike the rows,
/// it carries the full URLs.
///
/// Lives in the feature module rather than `StowerData` so user-facing wording
/// stays out of the data layer.
enum SyncDiagnosticsReport {
    static func text(diagnostics: SyncDiagnostics, status: CloudSyncStatus) -> String {
        var lines = ["Stower sync diagnostics", ""]

        lines.append("State: \(stateDescription(status.state))")
        if let detail = stateDetail(status.state) {
            lines.append("Detail: \(detail)")
        }
        lines.append("Last attempt: \(timestamp(status.lastSyncAttempt))")
        lines.append("Last success: \(timestamp(status.lastSyncSuccess))")
        lines.append("")

        lines.append("Synced rows: \(diagnostics.syncedItemsCount)")
        lines.append("Synced tags: \(diagnostics.syncedTagsCount)")
        lines.append("Synced item-tag links: \(diagnostics.syncedItemTagsCount)")
        lines.append("Pending changes: \(diagnostics.pendingChangesCount)")
        lines.append("Metadata rows: \(diagnostics.metadataCount)")

        if !diagnostics.sampleItems.isEmpty {
            lines.append("")
            lines.append("Latest synced items:")
            for item in diagnostics.sampleItems {
                lines.append("• \(item.title)")
                if let sourceURL = item.sourceURL, !sourceURL.isEmpty {
                    lines.append("  \(sourceURL)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func stateDescription(_ state: CloudSyncStatus.State) -> String {
        switch state {
        case .starting:
            return "Starting"
        case .available:
            return "On"
        case .unavailable:
            return "Off"
        case .error:
            return "Issue"
        case .needsLocalReset:
            return "Needs local reset"
        }
    }

    private static func stateDetail(_ state: CloudSyncStatus.State) -> String? {
        switch state {
        case .starting, .available:
            return nil
        case let .unavailable(reason), let .error(reason), let .needsLocalReset(reason):
            return reason
        }
    }

    private static func timestamp(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
