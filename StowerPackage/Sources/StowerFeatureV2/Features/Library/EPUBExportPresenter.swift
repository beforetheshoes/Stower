import ComposableArchitecture
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#endif

/// Hands a finished EPUB to the user: the system share sheet on iOS (Books,
/// Files, AirDrop) and a save panel on macOS. Also surfaces export failures.
struct EPUBExportPresenter: ViewModifier {
    let store: StoreOf<LibraryFeature>

    func body(content: Content) -> some View {
        content
            .alert(
                "Export Failed",
                isPresented: Binding(
                    get: { store.epubExportError != nil },
                    set: { if !$0 { store.send(.epubExportErrorDismissed) } }
                )
            ) {
                Button("OK") { store.send(.epubExportErrorDismissed) }
            } message: {
                Text(store.epubExportError ?? "")
            }
            .modifier(PlatformExportPresenter(store: store))
    }
}

#if os(iOS)
private struct PlatformExportPresenter: ViewModifier {
    let store: StoreOf<LibraryFeature>

    func body(content: Content) -> some View {
        content.sheet(
            item: Binding(
                get: { store.epubExport },
                set: { if $0 == nil { store.send(.epubExportDismissed) } }
            )
        ) { export in
            ActivityShareSheet(items: [export.fileURL]) {
                store.send(.epubExportDismissed)
            }
            .ignoresSafeArea()
        }
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onDismiss() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#elseif os(macOS)
private struct PlatformExportPresenter: ViewModifier {
    let store: StoreOf<LibraryFeature>

    func body(content: Content) -> some View {
        content.fileExporter(
            isPresented: Binding(
                get: { store.epubExport != nil },
                set: { if !$0 { store.send(.epubExportDismissed) } }
            ),
            item: store.epubExport.map(EPUBFileTransferable.init),
            contentTypes: [.epub],
            defaultFilename: store.epubExport?.suggestedFilename,
            onCompletion: { _ in store.send(.epubExportDismissed) },
            onCancellation: { store.send(.epubExportDismissed) }
        )
    }
}

private struct EPUBFileTransferable: Transferable {
    let url: URL
    let filename: String

    init(_ result: EPUBExportResult) {
        url = result.fileURL
        filename = "\(result.suggestedFilename).epub"
    }

    static var transferRepresentation: some TransferRepresentation {
        // The exporter builds an NSFileWrapper from this representation and
        // sets its preferred name from here, not from `defaultFilename`.
        // Leaving it unset yields an empty name, which Foundation rejects
        // with an uncaught exception.
        FileRepresentation(exportedContentType: .epub) { SentTransferredFile($0.url) }
            .suggestedFileName { $0.filename }
    }
}
#endif
