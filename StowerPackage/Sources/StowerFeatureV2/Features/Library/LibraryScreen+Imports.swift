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
        if store.saveState == .failed {
            store.send(.sourceURLChanged(""))
        }
        DispatchQueue.main.async {
            isAddURLPresented = true
        }
    }

    func presentTextImportSheet() {
        store.send(.addTextTapped)
        DispatchQueue.main.async {
            isTextImportPresented = true
        }
    }

    func presentTextFileImporter() {
        #if os(macOS)
        presentOpenPanel(
            allowedContentTypes: textImportContentTypes,
            title: "Import Text or Markdown"
        ) { url in
            handleTextImport(.success(url))
        }
        #else
        DispatchQueue.main.async {
            activeImportPicker = .text
        }
        #endif
    }

    func presentPDFImporter() {
        #if os(macOS)
        presentOpenPanel(
            allowedContentTypes: [.pdf],
            title: "Import PDF"
        ) { url in
            handlePDFImport(.success(url))
        }
        #else
        DispatchQueue.main.async {
            activeImportPicker = .pdf
        }
        #endif
    }

    func presentEPUBImporter() {
        #if os(macOS)
        presentOpenPanel(
            allowedContentTypes: [.epub],
            title: "Import EPUB"
        ) { url in
            handleEPUBImport(.success(url))
        }
        #else
        DispatchQueue.main.async {
            activeImportPicker = .epub
        }
        #endif
    }

    func presentWebsiteImporter() {
        #if os(macOS)
        presentOpenPanel(
            allowedContentTypes: [.zip],
            title: "Import Website Archive"
        ) { url in
            handleWebsiteImport(.success(url))
        }
        #else
        DispatchQueue.main.async {
            activeImportPicker = .website
        }
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

    /// Handles the result of the SwiftUI `.fileImporter` PDF picker. The
    /// picked URL is security-scoped — we must start/stop access around the
    /// copy, and we copy to a plain temp file so the reducer can consume a
    /// URL with no lifetime restrictions.
    /// Handles the result of a `.zip` website archive picker. Uses the same
    /// security-scoped + scratch-copy dance as `handlePDFImport` so the
    /// reducer consumes a plain temp URL with no lifetime restrictions.
    func handleWebsiteImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let pickedURL):
            let accessed = pickedURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { pickedURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let scratchDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: scratchDir,
                    withIntermediateDirectories: true
                )
                let scratch = scratchDir.appendingPathComponent(pickedURL.lastPathComponent)
                try FileManager.default.copyItem(at: pickedURL, to: scratch)
                store.send(.importWebsiteSelected(scratch))
            } catch {
                store.send(.saveURLFailed("Couldn't read zip: \(error.localizedDescription)"))
            }
        case .failure(let error):
            let ns = error as NSError
            if ns.code != NSUserCancelledError {
                store.send(.saveURLFailed("Website import failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Same security-scoped + scratch-copy handling as `handlePDFImport`. The
    /// original filename is kept: it is the title fallback for books whose
    /// package document has no title.
    func handleEPUBImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let pickedURL):
            let accessed = pickedURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { pickedURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let scratchDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: scratchDir,
                    withIntermediateDirectories: true
                )
                let scratch = scratchDir.appendingPathComponent(pickedURL.lastPathComponent)
                try FileManager.default.copyItem(at: pickedURL, to: scratch)
                store.send(.importEPUBSelected(scratch))
            } catch {
                store.send(.saveURLFailed("Couldn't read EPUB: \(error.localizedDescription)"))
            }
        case .failure(let error):
            let ns = error as NSError
            if ns.code != NSUserCancelledError {
                store.send(.saveURLFailed("EPUB import failed: \(error.localizedDescription)"))
            }
        }
    }

    func handlePDFImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let pickedURL):
            let accessed = pickedURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { pickedURL.stopAccessingSecurityScopedResource() }
            }
            do {
                // Copy into a unique temp subdirectory so we can preserve
                // the picked file's original name. PDFIngestionClient uses
                // the URL's `lastPathComponent` as the title fallback — if
                // we named the scratch file `{uuid}.pdf` the resulting item
                // would show up in the library titled with a raw UUID.
                let scratchDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: scratchDir,
                    withIntermediateDirectories: true
                )
                let scratch = scratchDir.appendingPathComponent(pickedURL.lastPathComponent)
                try FileManager.default.copyItem(at: pickedURL, to: scratch)
                store.send(.importPDFSelected(scratch))
            } catch {
                store.send(.saveURLFailed("Couldn't read PDF: \(error.localizedDescription)"))
            }
        case .failure(let error):
            // User cancellation shows up here as NSError cancelled — treat
            // anything that isn't a real failure as a silent dismiss. The
            // fileImporter modifier does not distinguish cancel from error,
            // so we only surface errors that carry a message.
            let ns = error as NSError
            if ns.code != NSUserCancelledError {
                store.send(.saveURLFailed("PDF import failed: \(error.localizedDescription)"))
            }
        }
    }

    func handleTextImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let pickedURL):
            let accessed = pickedURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { pickedURL.stopAccessingSecurityScopedResource() }
            }
            guard let mode = TextImportDetector.importMode(for: pickedURL) else {
                store.send(.saveURLFailed("Unsupported text file type."))
                return
            }
            do {
                let data = try Data(contentsOf: pickedURL)
                let text = decodedImportedText(from: data)
                let titleHint = TextImportDetector.normalizedTitleHint(from: pickedURL)
                store.send(.importTextResolved(text, titleHint, mode))
            } catch {
                store.send(.saveURLFailed("Couldn't read text file: \(error.localizedDescription)"))
            }
        case .failure(let error):
            let ns = error as NSError
            if ns.code != NSUserCancelledError {
                store.send(.saveURLFailed("Text import failed: \(error.localizedDescription)"))
            }
        }
    }

    #if os(iOS)
    enum IOSImportPicker: String, Identifiable {
        case text = "text"
        case pdf = "pdf"
        case epub = "epub"
        case website = "website"

        var id: String { rawValue }
    }

    func contentTypes(for picker: IOSImportPicker) -> [UTType] {
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
                        isAddURLPresented = false
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
            onCancel: {
                isTextImportPresented = false
                store.send(.textImportDismissed)
            },
            onSave: {
                store.send(.saveTextImportTapped)
            }
        )
    }

    func decodedImportedText(from data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .utf16LittleEndian) {
            return text
        }
        if let text = String(data: data, encoding: .utf16BigEndian) {
            return text
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
