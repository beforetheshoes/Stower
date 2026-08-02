import ComposableArchitecture
import SwiftUI

public struct SettingsScreen: View {
    @Bindable var store: StoreOf<SettingsFeature>
    @Environment(\.flexokiPalette)
    private var palette

    public init(store: StoreOf<SettingsFeature>) {
        self.store = store
    }

    public var body: some View {
        Form {
            Section("Sync") {
                LabeledContent("iCloud Sync") {
                    Text(syncSummary(store.cloudSyncStatus))
                        .foregroundStyle(.secondary)
                }

                if let detail = syncDetail(store.cloudSyncStatus) {
                    CopyableText(text: detail, font: .caption)
                }
            }

#if DEBUG
            if let diagnostics = store.diagnostics {
                Section("Sync Diagnostics") {
                    LabeledContent("Synced rows") {
                        Text("\(diagnostics.syncedItemsCount)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Synced tags") {
                        Text("\(diagnostics.syncedTagsCount)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Synced item-tag links") {
                        Text("\(diagnostics.syncedItemTagsCount)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Pending changes") {
                        Text("\(diagnostics.pendingChangesCount)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Metadata rows") {
                        Text("\(diagnostics.metadataCount)")
                            .foregroundStyle(.secondary)
                    }

                    if !diagnostics.sampleItems.isEmpty {
                        Text("Latest synced items")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(diagnostics.sampleItems) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.caption)
                                if let url = item.sourceURL {
                                    Text(url)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // One button producing a full pasteable dump, rather than a
                    // copy control on every row. The rows stay elided; the
                    // report carries the untruncated URLs.
                    CopyButton(
                        text: SyncDiagnosticsReport.text(
                            diagnostics: diagnostics,
                            status: store.cloudSyncStatus
                        )
                    )
                }
            }
#endif

            Section {
                Toggle(
                    "Automatically download images",
                    isOn: $store.settings.globalAutoDownload.sending(\.globalAutoDownloadChanged)
                )
                Toggle(
                    "Ask before new source downloads",
                    isOn: $store.settings.askForNewSources.sending(\.askForNewSourcesChanged)
                )
            }

            Section {
                reextractionRows
            } header: {
                Text("Reader")
            } footer: {
                Text(
                    """
                    Rebuilds saved articles from their source URLs using the \
                    current reader. Use this if older articles show broken \
                    tables, run-together code, or missing lists. Needs a \
                    network connection, re-downloads every article, and can \
                    take a while — you can stop at any point and pick it up \
                    again later.
                    """
                )
            }

            if let error = store.errorMessage {
                CopyableText(text: error, font: .body, textColor: palette.error)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(macOS)
        // macOS sheets auto-size to their content, but `Form` produces a
        // two-column layout whose label column has no minimum width — the
        // sheet ends up narrower than the labels need, and the labels
        // escape the dialog's visible area. Pinning the screen to a
        // reasonable minimum keeps every row inside the sheet.
        .frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 560)
        #endif
        .task {
            store.send(.load)
        }
    }

    @ViewBuilder private var reextractionRows: some View {
        switch store.reextraction {
        case .idle:
            Button("Re-extract All Articles") {
                store.send(.reextractLibraryTapped)
            }

        case .running(let progress):
            VStack(alignment: .leading, spacing: 8) {
                if progress.total > 0 {
                    ProgressView(value: progress.fraction) {
                        Text("Re-extracting \(progress.completed) of \(progress.total)")
                            .font(.callout)
                    }
                } else {
                    ProgressView {
                        Text("Preparing…")
                            .font(.callout)
                    }
                }

                if let title = progress.currentTitle {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if progress.failed > 0 {
                    Text(
                        progress.failed == 1
                            ? "1 couldn't be rebuilt and was left as it was."
                            : "\(progress.failed) couldn't be rebuilt and were left as they were."
                    )
                    .font(.caption)
                    .foregroundStyle(palette.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Stop", role: .cancel) {
                store.send(.reextractCancelTapped)
            }

        case .finished(let summary):
            VStack(alignment: .leading, spacing: 4) {
                Text(finishedHeadline(summary))
                    .font(.callout)
                if summary.failed > 0 {
                    Text(
                        summary.failed == 1
                            ? "1 article kept its previous version."
                            : "\(summary.failed) articles kept their previous version."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Done") {
                store.send(.reextractDismissed)
            }
        }
    }

    private func finishedHeadline(_ summary: LibraryReextractionState.Summary) -> String {
        if summary.wasCancelled {
            return summary.succeeded == 1
                ? "Stopped after rebuilding 1 article."
                : "Stopped after rebuilding \(summary.succeeded) articles."
        }
        if summary.succeeded == 0 && summary.failed == 0 {
            return "No articles to rebuild."
        }
        return summary.succeeded == 1
            ? "Rebuilt 1 article."
            : "Rebuilt \(summary.succeeded) articles."
    }

    private func syncSummary(_ status: CloudSyncStatus) -> String {
        switch status.state {
        case .starting:
            return "Starting"
        case .available:
            return "On"
        case .unavailable:
            return "Off"
        case .error:
            return "Issue"
        case .needsLocalReset:
            return "Attention"
        }
    }

    private func syncDetail(_ status: CloudSyncStatus) -> String? {
        switch status.state {
        case .starting, .available:
            if let date = status.lastSyncSuccess {
                return "Last synced: \(date.formatted(date: .abbreviated, time: .shortened))"
            }
            if let attempt = status.lastSyncAttempt {
                return "Last attempt: \(attempt.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Syncs your library list across devices on the same iCloud account."
        case .unavailable(let reason):
            return reason
        case .error(let message):
            return message
        case .needsLocalReset(let reason):
            return reason
        }
    }
}
