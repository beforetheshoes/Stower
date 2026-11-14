import SwiftUI

/// A save that is still being fetched, shown where the article will land.
struct LibraryPendingSaveRow: View {
    let save: PendingSave

    @Environment(\.flexokiPalette)
    private var palette

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(palette.tx)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(palette.tx2)
                    .lineLimit(1)
            }
            ProgressView()
                .controlSize(.small)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(status)")
        .accessibilityIdentifier("pendingSaveRow")
    }

    private var title: String {
        switch save.kind {
        case .url:
            FailedImport.displayURL(save.payload)
        case .pdf:
            // Imported files are staged under a generated name.
            "PDF"
        case .epub:
            "Book"
        default:
            "Website"
        }
    }

    private var status: String {
        if !save.isProcessing {
            "Waiting to save…"
        } else if save.kind == .url {
            "Saving…"
        } else {
            "Importing…"
        }
    }
}
