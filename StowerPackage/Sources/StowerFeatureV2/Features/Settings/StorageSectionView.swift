import ComposableArchitecture
import SwiftUI

/// The Settings → Storage section. Rendered inside `SettingsScreen`'s `Form`,
/// so it emits `Section`s rather than owning a container.
struct StorageSectionView: View {
    let store: StoreOf<StorageFeature>
    @Environment(\.flexokiPalette)
    private var palette

    var body: some View {
        Section {
            if let snapshot = store.snapshot {
                LabeledContent("Total") {
                    Text(Self.format(snapshot.totalBytes))
                        .foregroundStyle(.secondary)
                }
                breakdownRows(snapshot)
                if !snapshot.largestItems.isEmpty {
                    DisclosureGroup("Largest Items") {
                        ForEach(snapshot.largestItems) { item in
                            LabeledContent {
                                Text(Self.format(item.bytes))
                                    .foregroundStyle(.secondary)
                            } label: {
                                Text(item.title)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                }
            } else if store.isComputing {
                ProgressView {
                    Text("Measuring…")
                        .font(.callout)
                }
            }

            reclaimRows

            if let error = store.errorMessage {
                CopyableText(text: error, font: .caption, textColor: palette.error)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text(
                """
                Reclaiming space removes leftover temporary files, cleans up \
                data from deleted items, and compacts the database. Your saved \
                items are not affected.
                """
            )
        }
        .task {
            store.send(.task)
        }
    }

    @ViewBuilder
    private func breakdownRows(_ snapshot: StorageSnapshot) -> some View {
        LabeledContent("Database") {
            Text(Self.format(snapshot.databaseFileBytes + snapshot.databaseWALBytes))
                .foregroundStyle(.secondary)
        }
        LabeledContent("Saved Items") {
            Text(Self.format(snapshot.archiveBytes))
                .foregroundStyle(.secondary)
        }
        if snapshot.imagesBytes > 0 {
            LabeledContent("Images") {
                Text(Self.format(snapshot.imagesBytes))
                    .foregroundStyle(.secondary)
            }
        }
        if snapshot.cachesBytes > 0 {
            LabeledContent("Caches") {
                Text(Self.format(snapshot.cachesBytes))
                    .foregroundStyle(.secondary)
            }
        }
        if snapshot.pendingBytes > 0 {
            LabeledContent("Pending Imports") {
                Text(Self.format(snapshot.pendingBytes))
                    .foregroundStyle(.secondary)
            }
        }
        if snapshot.legacyDatabaseBytes > 0 {
            LabeledContent("Old Database Copy") {
                Text(Self.format(snapshot.legacyDatabaseBytes))
                    .foregroundStyle(.secondary)
            }
        }
        if snapshot.databaseReclaimableBytes > 0 {
            LabeledContent("Reclaimable") {
                Text(Self.format(snapshot.databaseReclaimableBytes))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var reclaimRows: some View {
        switch store.maintenance {
        case .idle:
            Button("Reclaim Space") {
                store.send(.reclaimTapped)
            }

        case .running:
            ProgressView {
                Text("Reclaiming space…")
                    .font(.callout)
            }

        case .finished(let report):
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    report.freedBytes > 0
                        ? "Freed \(Self.format(report.freedBytes))."
                        : "Nothing to reclaim."
                )
                .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Reclaim Again") {
                store.send(.reclaimTapped)
            }

        case .failed(let message):
            CopyableText(text: message, font: .caption, textColor: palette.error)
            Button("Try Again") {
                store.send(.reclaimTapped)
            }
        }
    }

    private static func format(_ bytes: Int) -> String {
        ByteCountFormatStyle(style: .file).format(Int64(bytes))
    }
}
