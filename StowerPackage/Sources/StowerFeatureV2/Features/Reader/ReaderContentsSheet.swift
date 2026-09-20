import SwiftUI

/// The reader's table of contents: the document's headings, indented by
/// level. Choosing one jumps the page to it.
struct ReaderContentsSheet: View {
    let entries: [ReaderContentsEntry]
    /// Index of the block at the top of the page, used to mark the section
    /// being read.
    let currentBlockIndex: Int?
    let onSelect: (ReaderContentsEntry) -> Void
    let onDone: () -> Void

    /// The last heading at or before the reading position.
    private var currentEntryID: Int? {
        guard let currentBlockIndex else { return nil }
        return entries.last { $0.blockIndex <= currentBlockIndex }?.id
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(entries) { entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        HStack {
                            Text(entry.title)
                                .font(entry.depth == 0 ? .body.weight(.medium) : .body)
                                .foregroundStyle(entry.depth == 0 ? .primary : .secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .padding(.leading, CGFloat(entry.depth) * 16)
                            Spacer(minLength: 8)
                            if entry.id == currentEntryID {
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Current section")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(entry.id)
                }
                .onAppear {
                    if let currentEntryID {
                        proxy.scrollTo(currentEntryID, anchor: .center)
                    }
                }
            }
            .navigationTitle("Contents")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 440)
        #endif
    }
}
