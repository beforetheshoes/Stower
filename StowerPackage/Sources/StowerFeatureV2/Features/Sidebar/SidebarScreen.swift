import ComposableArchitecture
import SwiftUI

public struct SidebarScreen: View {
    @Bindable var store: StoreOf<SidebarFeature>
    /// Optional hook so the parent (AppFeature) can present Settings on demand.
    public var onOpenSettings: (() -> Void)? = nil
    /// When non-nil, rows render as Buttons instead of NavigationLinks. Used
    /// by the iPhone filter sheet, where the sidebar is presented modally and
    /// row selection should dismiss the sheet rather than push a column.
    public var onSelect: ((LibraryFilter) -> Void)? = nil

    public init(
        store: StoreOf<SidebarFeature>,
        onOpenSettings: (() -> Void)? = nil,
        onSelect: ((LibraryFilter) -> Void)? = nil
    ) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.onSelect = onSelect
    }

    public var body: some View {
        List(selection: Binding(
            get: { store.selection },
            set: { newValue in
                if let newValue { store.send(.selectList(newValue)) }
            }
        )) {
            Section("Lists") {
                listRow(.all, label: "All", systemImage: "tray.full", count: store.counts.all)
                listRow(.unread, label: "Unread", systemImage: "circle.fill", count: store.counts.unread)
                listRow(.starred, label: "Starred", systemImage: "star.fill", count: store.counts.starred)
                listRow(.untagged, label: "Untagged", systemImage: "tag.slash", count: store.counts.untagged)
                listRow(.read, label: "Read", systemImage: "checkmark.circle", count: store.counts.read)
                listRow(.recentlyDeleted, label: "Recently Deleted", systemImage: "trash", count: store.counts.recentlyDeleted)
            }

            Section {
                ForEach(store.tags) { tag in
                    tagRow(tag)
                }
            } header: {
                HStack {
                    Text("Tags")
                    Spacer()
                    Button {
                        store.send(.newTagTapped)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("New Tag")
                }
            }
        }
        .navigationTitle("Stower")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if onOpenSettings != nil {
                Button {
                    onOpenSettings?()
                } label: {
                    Label("Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderless)
                .padding(12)
            }
        }
        .alert(
            "New Tag",
            isPresented: Binding(
                get: { store.isCreatingTag },
                set: { if !$0 { store.send(.newTagDismissed) } }
            )
        ) {
            TextField("Tag name", text: Binding(
                get: { store.newTagName },
                set: { store.send(.newTagNameChanged($0)) }
            ))
            Button("Cancel", role: .cancel) { store.send(.newTagDismissed) }
            Button("Create") { store.send(.newTagConfirmed) }
        }
        .alert(
            "Rename Tag",
            isPresented: Binding(
                get: { store.renamingTag != nil },
                set: { if !$0 { store.send(.renameTagDismissed) } }
            )
        ) {
            TextField("Tag name", text: Binding(
                get: { store.renamingTag?.name ?? "" },
                set: { store.send(.renameTagNameChanged($0)) }
            ))
            Button("Cancel", role: .cancel) { store.send(.renameTagDismissed) }
            Button("Rename") { store.send(.renameTagConfirmed) }
        }
        .task { store.send(.onAppear) }
    }

    @ViewBuilder
    private func listRow(
        _ filter: LibraryFilter,
        label: String,
        systemImage: String,
        count: Int
    ) -> some View {
        if onSelect != nil {
            // Sheet mode: dispatch and notify the host so it can dismiss.
            // The List(selection:) binding does not fire from Button taps,
            // so we mark the active filter with a trailing checkmark.
            Button {
                store.send(.selectList(filter))
                onSelect?(filter)
            } label: {
                HStack {
                    Label(label, systemImage: systemImage)
                    Spacer()
                    if store.selection == filter {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .badge(count)
        } else {
            NavigationLink(value: filter) {
                Label(label, systemImage: systemImage)
            }
            .badge(count)
            .tag(filter)
        }
    }

    @ViewBuilder
    private func tagRow(_ tag: Tag) -> some View {
        let filter = LibraryFilter.tag(tag.id)
        Group {
            if onSelect != nil {
                Button {
                    store.send(.selectList(filter))
                    onSelect?(filter)
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(tagColor(tag.colorHex))
                            .frame(width: 10, height: 10)
                        Text(tag.name)
                        Spacer()
                        if store.selection == filter {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .badge(store.counts.byTag[tag.id] ?? 0)
            } else {
                NavigationLink(value: filter) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(tagColor(tag.colorHex))
                            .frame(width: 10, height: 10)
                        Text(tag.name)
                    }
                }
                .badge(store.counts.byTag[tag.id] ?? 0)
                .tag(filter)
            }
        }
        .contextMenu {
            Button("Rename") { store.send(.renameTagTapped(tag)) }
            Button("Delete", role: .destructive) { store.send(.deleteTagTapped(tag.id)) }
        }
    }

    private func tagColor(_ hex: String?) -> Color {
        // Color parsing is a follow-up; for now every tag uses the accent color.
        return .accentColor
    }
}
