import ComposableArchitecture
import Foundation

@Reducer
public struct LibraryFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var items: [SavedItem] = []
        public var query = ""
        public var sourceURL = ""
        public var isLoading = false
        public var isSaving = false
        public var saveState: ProcessingState = .queued
        public var errorMessage: String?

        public var filteredItems: [SavedItem] {
            guard !query.isEmpty else { return items }
            return items.filter {
                $0.title.localizedStandardContains(query)
                || ($0.sourceURL?.localizedStandardContains(query) ?? false)
                || ($0.siteName?.localizedStandardContains(query) ?? false)
            }
        }

        public init() {}
    }

    public enum Action: Equatable {
        case reload
        case response([SavedItem])
        case failed(String)
        case queryChanged(String)
        case deleteItem(UUID)
        case deleteFinished
        case deleteFailed(String)
        case openItem(SavedItem)
        case reprocessItem(UUID)
        case reprocessFinished(SavedItem)
        case sourceURLChanged(String)
        case saveURLTapped
        case saveURLFinished(SavedItem)
        case saveURLFailed(String)
    }

    @Dependency(\.stowerRepository) var repository
    @Dependency(\.urlIngestionClient) var ingestionClient

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .reload:
                state.isLoading = true
                state.errorMessage = nil
                let repository = self.repository
                return .run { send in
                    do {
                        let items = try await repository.fetchLibrary()
                        await send(.response(items))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .response(let items):
                state.isLoading = false
                state.items = items
                return .none

            case .failed(let error):
                state.isLoading = false
                state.errorMessage = error
                return .none

            case .queryChanged(let value):
                state.query = value
                return .none

            case .sourceURLChanged(let value):
                state.sourceURL = value
                if state.saveState == .failed {
                    state.saveState = .queued
                }
                return .none

            case .saveURLTapped:
                let sourceURL = state.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let normalizedURL = normalizeSourceURL(sourceURL),
                      let url = URL(string: normalizedURL)
                else {
                    state.errorMessage = "Enter a valid source URL."
                    state.saveState = .failed
                    return .none
                }

                state.errorMessage = nil
                state.isSaving = true
                state.saveState = .extracting
                let repository = self.repository
                let ingestionClient = self.ingestionClient
                return .run { send in
                    do {
                        let result = try await ingestionClient.ingest(url)
                        let item = try await repository.createItemFromIngestion(result)

                        // Archive all external assets for offline WebView rendering.
                        if result.renderFormat == .webView,
                           !result.sourceHTML.isEmpty,
                           let source = result.sourceURL,
                           let baseURL = URL(string: source) {
                            await AssetArchiver.archiveAssets(
                                html: result.sourceHTML,
                                baseURL: baseURL,
                                itemID: item.id
                            )
                        }

                        await send(.saveURLFinished(item))
                        await send(.openItem(item))
                    } catch {
                        await send(.saveURLFailed(error.localizedDescription))
                    }
                }

            case .saveURLFinished(let item):
                state.isSaving = false
                state.saveState = .ready
                state.sourceURL = ""
                // Insert at the top instead of reloading entire library
                state.items.insert(item, at: 0)
                return .none

            case .saveURLFailed(let error):
                state.isSaving = false
                state.saveState = .failed
                state.errorMessage = error
                return .none

            case .deleteItem(let id):
                // Optimistic removal — update UI immediately, delete in background
                state.items.removeAll { $0.id == id }
                let repository = self.repository
                return .run { send in
                    do {
                        try await repository.deleteItem(id)
                        AssetArchiver.deleteArchive(for: id)
                        await send(.deleteFinished)
                    } catch {
                        await send(.deleteFailed(error.localizedDescription))
                    }
                }

            case .reprocessItem(let id):
                // Mark extracting in UI immediately
                if let idx = state.items.firstIndex(where: { $0.id == id }) {
                    state.items[idx].processingState = .extracting
                }
                let repository = self.repository
                let ingestionClient = self.ingestionClient
                return .run { send in
                    do {
                        guard let item = try await repository.loadItem(id),
                              let source = item.sourceURL,
                              let url = URL(string: source)
                        else {
                            await send(.failed("Source URL unavailable for refresh."))
                            return
                        }

                        let result = try await ingestionClient.ingest(url)
                        guard let updatedItem = try await repository.updateItemFromIngestion(id, result) else {
                            await send(.failed("This item no longer exists."))
                            return
                        }

                        // Re-archive assets for offline WebView rendering.
                        if result.renderFormat == .webView,
                           !result.sourceHTML.isEmpty,
                           let source = result.sourceURL,
                           let baseURL = URL(string: source) {
                            AssetArchiver.deleteArchive(for: id)
                            await AssetArchiver.archiveAssets(
                                html: result.sourceHTML,
                                baseURL: baseURL,
                                itemID: id
                            )
                        }

                        await send(.reprocessFinished(updatedItem))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .deleteFailed(let error):
                state.errorMessage = error
                return .none

            case .reprocessFinished(let updatedItem):
                if let idx = state.items.firstIndex(where: { $0.id == updatedItem.id }) {
                    state.items[idx] = updatedItem
                }
                return .none

            case .deleteFinished, .openItem:
                return .none
            }
        }
    }
}

private func normalizeSourceURL(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.contains("://") {
        return trimmed
    }

    if trimmed.contains(".") {
        return "https://\(trimmed)"
    }
    return nil
}
