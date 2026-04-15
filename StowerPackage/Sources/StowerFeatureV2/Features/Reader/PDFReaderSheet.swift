import PDFKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Sheet that presents the original PDF bytes of a PDF-ingested item in a
/// native `PDFKit.PDFView`. Reached from the reader toolbar on items whose
/// `renderFormat == .pdf`. If the PDF file isn't on this device (CloudKit
/// synced the metadata but the bytes never sync), shows a placeholder
/// explaining that the PDF needs to be re-shared on this device.
struct PDFReaderSheet: View {
    let itemID: UUID
    let title: String
    let onDismiss: () -> Void

    /// A shared command bus that `PDFKitView` reads on update to run
    /// user-driven actions (next/prev page, zoom in/out) against its
    /// underlying `PDFView` instance.
    @State private var command = PDFCommand()

    var body: some View {
        NavigationStack {
            Group {
                if let url = existingPDFURL() {
                    PDFKitView(url: url, command: command)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    unavailableView
                }
            }
            .navigationTitle(title.isEmpty ? "PDF" : title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if existingPDFURL() != nil {
                    ToolbarItemGroup(placement: .automatic) {
                        Button {
                            command.kind = .previousPage
                            command.tick &+= 1
                        } label: {
                            Label("Previous Page", systemImage: "chevron.up")
                        }
                        Button {
                            command.kind = .nextPage
                            command.tick &+= 1
                        } label: {
                            Label("Next Page", systemImage: "chevron.down")
                        }
                        Button {
                            command.kind = .zoomOut
                            command.tick &+= 1
                        } label: {
                            Label("Zoom Out", systemImage: "minus.magnifyingglass")
                        }
                        Button {
                            command.kind = .zoomIn
                            command.tick &+= 1
                        } label: {
                            Label("Zoom In", systemImage: "plus.magnifyingglass")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        #if os(macOS)
        // Without an explicit frame the macOS sheet collapses to the
        // intrinsic size of its toolbar (~200×60), leaving PDFView with
        // zero space to render. Give it a sensible default and let the
        // user drag it bigger.
        .frame(minWidth: 800, idealWidth: 900, minHeight: 600, idealHeight: 900)
        #endif
    }

    private func existingPDFURL() -> URL? {
        let url = PDFArchiver.pdfURL(for: itemID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var unavailableView: some View {
        VStack(spacing: 14) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityLabel("PDF not available")
            Text("PDF not available")
                .font(.headline)
            Text("This PDF was shared from another device. The extracted text is synced to this device, but the original PDF file isn't. Re-share the PDF on this device to restore the original view.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One-shot command issued from the toolbar. `tick` is bumped by each
/// button press so `update*View` can detect "the user clicked again"
/// without missing a command that happens to share the same `kind` as the
/// previous one.
private struct PDFCommand: Equatable {
    enum Kind: Equatable {
        case none
        case previousPage
        case nextPage
        case zoomIn
        case zoomOut
    }
    var kind: Kind = .none
    var tick: UInt = 0
}

@MainActor
private func applyCommand(_ command: PDFCommand, to pdfView: PDFView) {
    switch command.kind {
    case .none:
        break
    case .previousPage:
        if pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) }
    case .nextPage:
        if pdfView.canGoToNextPage { pdfView.goToNextPage(nil) }
    case .zoomIn:
        if pdfView.canZoomIn { pdfView.zoomIn(nil) }
    case .zoomOut:
        if pdfView.canZoomOut { pdfView.zoomOut(nil) }
    }
}

// MARK: - PDFKit bridge

#if canImport(UIKit)
private struct PDFKitView: UIViewRepresentable {
    let url: URL
    let command: PDFCommand

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(false)
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            pdfView.document = PDFDocument(url: url)
        }
        if command.tick != context.coordinator.lastTick {
            context.coordinator.lastTick = command.tick
            applyCommand(command, to: pdfView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastTick: UInt = 0
    }
}
#elseif canImport(AppKit)
private struct PDFKitView: NSViewRepresentable {
    let url: URL
    let command: PDFCommand

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            pdfView.document = PDFDocument(url: url)
        }
        if command.tick != context.coordinator.lastTick {
            context.coordinator.lastTick = command.tick
            applyCommand(command, to: pdfView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastTick: UInt = 0
    }
}
#endif
