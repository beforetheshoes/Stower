import StowerData
import SwiftUI

enum TextAuthoringPreviewSupport {
    enum Kind: Equatable {
        case plainText
        case markdown
    }

    static func kind(for text: String, mode: TextImportMode) -> Kind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMode = TextImportDetector.inferredMode(for: trimmed, preferred: mode)
        return resolvedMode == .markdown ? .markdown : .plainText
    }

    static func previewHTML(
        text: String,
        title: String,
        mode: TextImportMode,
        appearance: ReaderAppearanceSettings = .init()
    ) -> String {
        let result: IngestionResult
        switch kind(for: text, mode: mode) {
        case .markdown:
            result = markdownIngestionResult(
                markdown: text,
                explicitTitle: title.isEmpty ? nil : title,
                titleHint: nil
            )
        case .plainText:
            result = IngestionResult.sharedText(
                text,
                explicitTitle: title.isEmpty ? nil : title
            )
        }

        let item = SavedItem(
            title: result.title,
            content: result.plainText,
            renderFormat: result.renderFormat,
            documentVersion: result.document.version
        )
        return ReaderDocumentHTMLBuilder.buildReaderHTML(
            item: item,
            document: result.document,
            appearance: appearance
        )
    }
}

private enum TextAuthoringPane: String, CaseIterable, Identifiable {
    case write = "Write"
    case preview = "Preview"

    var id: String { rawValue }
}

public struct TextAuthoringSheet: View {
    @Binding var title: String
    @Binding var text: String
    @Binding var mode: TextImportMode
    let palette: FlexokiPalette
    let appearance: ReaderAppearanceSettings
    let errorMessage: String?
    let isSaving: Bool
    let navigationTitle: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @State private var activePane: TextAuthoringPane = .write
    @State private var previewItemID = UUID()

    public init(
        title: Binding<String>,
        text: Binding<String>,
        mode: Binding<TextImportMode>,
        palette: FlexokiPalette,
        errorMessage: String?,
        isSaving: Bool,
        navigationTitle: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping () -> Void,
        appearance: ReaderAppearanceSettings = .init()
    ) {
        self._title = title
        self._text = text
        self._mode = mode
        self.palette = palette
        self.appearance = appearance
        self.errorMessage = errorMessage
        self.isSaving = isSaving
        self.navigationTitle = navigationTitle
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var previewKind: TextAuthoringPreviewSupport.Kind {
        TextAuthoringPreviewSupport.kind(for: text, mode: mode)
    }

    private var previewHTML: String {
        TextAuthoringPreviewSupport.previewHTML(
            text: text,
            title: title,
            mode: mode,
            appearance: appearance
        )
    }

    private var previewContentVersion: Int {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(title)
        hasher.combine(mode.rawValue)
        return hasher.finalize()
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)

                VStack(spacing: 12) {
                    Picker("Format", selection: $mode) {
                        Text("Auto").tag(TextImportMode.auto)
                        Text("Plain Text").tag(TextImportMode.plainText)
                        Text("Markdown").tag(TextImportMode.markdown)
                    }
                    .pickerStyle(.segmented)

                    Picker("Pane", selection: $activePane) {
                        ForEach(TextAuthoringPane.allCases) { pane in
                            Text(pane.rawValue).tag(pane)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Group {
                    switch activePane {
                    case .write:
                        editor
                    case .preview:
                        preview
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)

                footer
            }
            .padding()
            .navigationTitle(navigationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 640, idealWidth: 720, maxWidth: 900, minHeight: 460, idealHeight: 560)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", action: onSave)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(mode == .markdown ? .body.monospaced() : .body)
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var preview: some View {
        Group {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Nothing to preview yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(18)
                    .background(palette.ui.opacity(0.28), in: .rect(cornerRadius: 12))
            } else {
                ReaderWebView(
                    html: { previewHTML },
                    sourceURL: nil,
                    itemID: previewItemID,
                    contentVersion: previewContentVersion,
                    appearance: .init(),
                    isWebViewFormat: false
                )
                .clipShape(.rect(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(palette.error)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if previewKind == .markdown {
            Text("Write in markdown, then switch to Preview to inspect the rendered formatting without losing the source.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Write plain text or markdown. Auto mode detects markdown-like syntax for imported text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
