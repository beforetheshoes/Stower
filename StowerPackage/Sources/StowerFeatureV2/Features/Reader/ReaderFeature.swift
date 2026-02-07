import ComposableArchitecture
import Foundation

@Reducer
public struct ReaderFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var itemID: UUID
        public var item: SavedItem?
        public var document: ReaderDocument?
        public var isLoading = false
        public var errorMessage: String?
        @Presents public var inlineEmbedURL: InlineEmbedFeature.State?

        public init(itemID: UUID) {
            self.itemID = itemID
        }
    }

    public enum Action: Equatable {
        case load
        case loaded(SavedItem?, ReaderDocument?)
        case failed(String)
        case retryExtractionTapped
        case retryFinished(SavedItem?)
        case openInlineWebEmbed(String)
        case inlineEmbedURL(PresentationAction<InlineEmbedFeature.Action>)
    }

    @Dependency(\.stowerRepository) var repository
    @Dependency(\.urlIngestionClient) var ingestionClient

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .load:
                state.isLoading = true
                state.errorMessage = nil
                let repository = self.repository
                return .run { [id = state.itemID] send in
                    do {
                        async let item = repository.loadItem(id)
                        async let document = repository.loadReaderDocument(id)
                        await send(.loaded(try item, try document))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .loaded(let item, let document):
                state.isLoading = false
                state.item = item
                state.document = document
                return .none

            case .failed(let error):
                state.isLoading = false
                state.errorMessage = error
                return .none

            case .retryExtractionTapped:
                guard let source = state.item?.sourceURL,
                      let url = URL(string: source)
                else {
                    state.errorMessage = "Source URL unavailable for refresh."
                    return .none
                }

                state.isLoading = true
                let repository = self.repository
                let ingestionClient = self.ingestionClient
                return .run { [id = state.itemID] send in
                    do {
                        let result = try await ingestionClient.ingest(url)
                        let item = try await repository.updateItemFromIngestion(id, result)
                        await send(.retryFinished(item))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .retryFinished(let item):
                if let item {
                    state.item = item
                    return .send(.load)
                } else {
                    state.isLoading = false
                    state.errorMessage = "Unable to refresh this item."
                    return .none
                }

            case .openInlineWebEmbed(let urlString):
                guard let url = URL(string: urlString) else {
                    return .none
                }
                state.inlineEmbedURL = InlineEmbedFeature.State(url: url)
                return .none

            case .inlineEmbedURL:
                return .none
            }
        }
        .ifLet(\.$inlineEmbedURL, action: \.inlineEmbedURL) {
            InlineEmbedFeature()
        }
    }
}

@Reducer
public struct InlineEmbedFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var url: URL

        public init(url: URL) {
            self.url = url
        }
    }

    public enum Action: Equatable {
        case close
    }

    public var body: some ReducerOf<Self> {
        Reduce { _, action in
            switch action {
            case .close:
                return .none
            }
        }
    }
}
