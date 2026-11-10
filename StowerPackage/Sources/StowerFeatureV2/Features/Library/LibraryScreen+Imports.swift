import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Adding content: the Add URL and text sheets, the file pickers, and what
// happens to a picked file.
extension LibraryScreen {
    func presentAddURLSheet() {
        store.send(.addURLButtonTapped)
    }

    func presentTextImportSheet() {
        store.send(.addTextTapped)
    }

    func presentTextFileImporter() {
        #if os(macOS)
        presentOpenPanel(
            allowedContentTypes: textImportContentTypes,
            title: "Import Text or Markdown"
        ) { url in
            store.send(.filePicked(.text, url))
        }
        #else
        store.send(.importPickerRequested(.text))
        #endif
    }

    func presentPDFImporter() {
        #if os(macOS)
        presentOpenPanel(
            allowedContentTypes: [.pdf],
            title: "Import PDF"
        ) { url in
            store.send(.filePicked(.pdf, url))
        }
        #else
        store.send(.importPickerRequested(.pdf))
        #endif
    }

    func presentEPUBImporter() {
        #if os(macOS)
        presentOpenPanel(
            allowedContentTypes: [.epub],
            title: "Import EPUB"
        ) { url in
            store.send(.filePicked(.epub, url))
        }
        #else
        store.send(.importPickerRequested(.epub))
        #endif
    }

    func presentWebsiteImporter() {
        #if os(macOS)
        presentOpenPanel(
            allowedContentTypes: [.zip],
            title: "Import Website Archive"
        ) { url in
            store.send(.filePicked(.website, url))
        }
        #else
        store.send(.importPickerRequested(.website))
        #endif
    }

    #if os(macOS)
    func presentOpenPanel(
        allowedContentTypes: [UTType],
        title: String,
        onSelect: @escaping (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onSelect(url)
        }
    }
    #endif

    var textImportContentTypes: [UTType] {
        let markdownTypes = [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
        ].compactMap { $0 }
        return [.plainText] + markdownTypes
    }

    /// Describes one dropped URL for the reducer.
    ///
    /// A dropped file is copied here, before the drop handler returns: the
    /// access the system grants for a drop is not promised to outlive the
    /// handler, and the reducer's effects run after it.
    func droppedItem(_ url: URL) -> LibraryDroppedItem {
        guard url.isFileURL else { return .link(url) }
        guard let kind = LibraryImportPicker(droppedFile: url) else {
            return .unsupported(url.lastPathComponent)
        }
        do {
            return .file(kind, try pickedFileClient.stage(url))
        } catch {
            return .unreadable(kind, error.localizedDescription)
        }
    }

    /// Passes a picker's result to the reducer. Cancelling arrives here as an
    /// error too; it is not one.
    func handlePickedFile(_ picker: LibraryImportPicker, _ result: Result<URL, Error>) {
        switch result {
        case .success(let pickedURL):
            store.send(.filePicked(picker, pickedURL))
        case .failure(let error):
            guard (error as NSError).code != NSUserCancelledError else { return }
            store.send(.filePickFailed(picker, error.localizedDescription))
        }
    }

    #if os(iOS)
    func contentTypes(for picker: LibraryImportPicker) -> [UTType] {
        switch picker {
        case .text:
            return textImportContentTypes
        case .pdf:
            return [.pdf]
        case .epub:
            return [.epub]
        case .website:
            return [.zip]
        }
    }

    struct IOSDocumentPicker: UIViewControllerRepresentable {
        let allowedContentTypes: [UTType]
        let onComplete: (Result<URL, Error>) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onComplete: onComplete)
        }

        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            let controller = UIDocumentPickerViewController(
                forOpeningContentTypes: allowedContentTypes,
                asCopy: false
            )
            controller.delegate = context.coordinator
            controller.allowsMultipleSelection = false
            return controller
        }

        func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

        final class Coordinator: NSObject, UIDocumentPickerDelegate {
            private let onComplete: (Result<URL, Error>) -> Void

            init(onComplete: @escaping (Result<URL, Error>) -> Void) {
                self.onComplete = onComplete
            }

            func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
                guard let url = urls.first else {
                    onComplete(.failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
                    return
                }
                onComplete(.success(url))
            }

            func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
                onComplete(.failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
            }
        }
    }

    /// Modal URL-entry form shown when the user taps the toolbar "+".
    @ViewBuilder var addURLSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "https://example.com/article",
                        text: $store.sourceURL.sending(\.sourceURLChanged)
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($isURLFieldFocused)
                    .onSubmit { store.send(.saveURLTapped) }
                    if store.saveState == .failed, let error = store.errorMessage {
                        // Deliberately a row, not the section footer: a footer
                        // renders interactive controls at footnote size outside
                        // the grouped inset, so the copy button would be almost
                        // untappable and read as decoration.
                        CopyableText(text: error, textColor: palette.error)
                    }
                } header: {
                    Text("URL")
                } footer: {
                    Text("Paste any article URL. Stower saves it in the background and adds it to your Inbox when it is ready.")
                }
            }
            .navigationTitle("Add URL")
            .navigationBarTitleDisplayMode(.inline)
            // The field is the whole point of the sheet; put the cursor in it.
            // `defaultFocus` covers the normal case; the delayed set covers
            // sheets whose presentation finishes after focus is resolved.
            .defaultFocus($isURLFieldFocused, true)
            .task {
                try? await Task.sleep(for: .milliseconds(350))
                isURLFieldFocused = true
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.send(.addURLPresentationChanged(false))
                    }
                    .disabled(store.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.isSaving {
                        ProgressView()
                    } else {
                        Button("Add") {
                            store.send(.saveURLTapped)
                        }
                        .disabled(store.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(store.isSaving)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    #endif

    @ViewBuilder var textImportSheet: some View {
        TextAuthoringSheet(
            title: Binding(
                get: { store.textImportDraft?.title ?? "" },
                set: { store.send(.textImportTitleChanged($0)) }
            ),
            text: Binding(
                get: { store.textImportDraft?.text ?? "" },
                set: { store.send(.textImportTextChanged($0)) }
            ),
            mode: Binding(
                get: { store.textImportDraft?.mode ?? .auto },
                set: { store.send(.textImportModeChanged($0)) }
            ),
            palette: palette,
            errorMessage: store.saveState == .failed ? store.errorMessage : nil,
            isSaving: store.isSaving,
            navigationTitle: "Add Text",
            onCancel: { store.send(.textImportDismissed) },
            onSave: {
                store.send(.saveTextImportTapped)
            }
        )
    }
}
