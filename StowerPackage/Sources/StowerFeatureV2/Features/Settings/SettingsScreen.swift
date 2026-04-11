import ComposableArchitecture
import SwiftUI

public struct SettingsScreen: View {
    @Bindable var store: StoreOf<SettingsFeature>

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
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

#if DEBUG
            if let diagnostics = store.diagnostics {
                Section("Sync Diagnostics") {
                    LabeledContent("Synced rows") {
                        Text("\(diagnostics.syncedItemsCount)")
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

            if let error = store.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
