import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Row menus, the empty state, the title, and the Mac inline composer.
extension LibraryScreen {
    // MARK: - Tag Pills

    func resolvedTags(for item: SavedItem) -> [Tag] {
        item.tagIDs.compactMap { id in
            store.availableTags.first { $0.id == id }
        }
    }

    @ViewBuilder var libraryEmptyState: some View {
        if !store.query.isEmpty {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("Try another title, publication, tag, or phrase from the article.")
            )
        } else {
            switch store.filter {
            case .unread:
                ContentUnavailableView {
                    Label("Inbox Zero", systemImage: "checkmark.circle")
                } description: {
                    Text("Nothing is waiting to be read. Completed articles stay available in Library, Starred, and Tags.")
                } actions: {
                    #if os(iOS)
                    Button("Add a Link", systemImage: "link", action: presentAddURLSheet)
                        .buttonStyle(.borderedProminent)
                    #endif
                }
            case .all:
                ContentUnavailableView {
                    Label(String(localized: "Your Library Is Empty"), systemImage: "books.vertical")
                } description: {
                    Text("Save an article or website to keep it here for reading and future reference.")
                } actions: {
                    #if os(iOS)
                    Button("Add a Link", systemImage: "link", action: presentAddURLSheet)
                        .buttonStyle(.borderedProminent)
                    #endif
                }
            default:
                ContentUnavailableView(
                    "Nothing Here Yet",
                    systemImage: "tray",
                    description: Text("Articles that match this list will appear here.")
                )
            }
        }
    }

    // MARK: - Tags Submenu

    @ViewBuilder
    func tagsSubmenu(for item: SavedItem) -> some View {
        Menu {
            ForEach(store.availableTags) { tag in
                Button {
                    store.send(.toggleTagOnItem(item.id, tag.id))
                } label: {
                    if item.tagIDs.contains(tag.id) {
                        Label(tag.name, systemImage: "checkmark")
                    } else {
                        Text(tag.name)
                    }
                }
            }
            Divider()
            Button {
                store.send(.inlineCreateTagTapped(item.id))
            } label: {
                Label("New Tag\u{2026}", systemImage: "plus")
            }
        } label: {
            Label("Tags", systemImage: "tag")
        }
    }

    // MARK: - Download Management

    /// Context-menu entries for items whose heavy content can live in
    /// iCloud: PDFs, website imports, and interactive captures. Regular
    /// articles get no entries — their content always stays local.
    @ViewBuilder
    func downloadManagementMenuItems(for item: SavedItem) -> some View {
        if let info = store.storageInfoByID[item.id] {
            if info.offloadedAt != nil {
                Button {
                    store.send(.downloadNow(item.id))
                } label: {
                    Label("Download Now", systemImage: "icloud.and.arrow.down")
                }
            } else if StorageOffloadService.canOffload(info) {
                Button {
                    store.send(.removeDownload(item.id))
                } label: {
                    Label("Remove Download", systemImage: "xmark.icloud")
                }
            }
            if info.offloadedAt != nil || StorageOffloadService.canOffload(info) || info.isPinned {
                Button {
                    store.send(.setPinned(item.id, !info.isPinned))
                } label: {
                    if info.isPinned {
                        Label("Keep Downloaded", systemImage: "checkmark")
                    } else {
                        Text("Keep Downloaded")
                    }
                }
            }
        }
    }

    var navigationTitle: String {
        switch store.filter {
        case .all:
            return "Library"
        case .unread:
            return "Inbox"
        case .read:
            return "Read"
        case .starred:
            return "Starred"
        case .untagged:
            return "Untagged"
        case .recentlyDeleted:
            return "Recently Deleted"
        case let .tag(id):
            return store.availableTags.first { $0.id == id }?.name ?? "Tag"
        }
    }

    @ViewBuilder var urlComposer: some View {
        HStack(spacing: 10) {
            TextField("Paste article URL", text: $store.sourceURL.sending(\.sourceURLChanged))
                .autocorrectionDisabled()
                #if os(iOS)
                // iOS TextField defaults to `.sentences` which capitalizes
                // the first character. Without this modifier "https://…"
                // becomes "Https://…" and downstream parsers silently fail.
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                // Liquid Glass input chip — the composer floats above the
                // library list as frosted glass, refracting whatever rows
                // sit beneath it instead of the old flat 6% opacity fill.
                .glassEffect(.regular, in: .rect(cornerRadius: 6))
                .onSubmit { store.send(.saveURLTapped) }

            #if os(macOS)
            Button {
                store.send(store.isSaving ? .cancelURLSaveTapped : .saveURLTapped)
            } label: {
                if store.isSaving {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                } else {
                    Label("Add", systemImage: "plus.circle.fill")
                }
            }
            .buttonStyle(.glassProminent)
            .fixedSize()

            Menu {
                Section("Text") {
                    Button {
                        presentTextImportSheet()
                    } label: {
                        Label("Write or Paste Text…", systemImage: "square.and.pencil")
                    }
                }

                Section("Import") {
                    Button {
                        presentTextFileImporter()
                    } label: {
                        Label("Import Text/Markdown…", systemImage: "doc.text")
                    }

                    Button {
                        presentPDFImporter()
                    } label: {
                        Label("Import PDF…", systemImage: "doc.richtext")
                    }

                    Button {
                        presentEPUBImporter()
                    } label: {
                        Label("Import EPUB…", systemImage: "book")
                    }

                    Button {
                        presentWebsiteImporter()
                    } label: {
                        Label("Import Website Archive…", systemImage: "globe")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
            .disabled(store.isSaving)
            #else
            Button {
                store.send(store.isSaving ? .cancelURLSaveTapped : .saveURLTapped)
            } label: {
                if store.isSaving {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                } else {
                    Label("Add URL", systemImage: "plus.circle.fill")
                }
            }
            #endif
        }
    }
}
