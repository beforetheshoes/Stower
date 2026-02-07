import ComposableArchitecture
import Foundation

@Reducer
public struct AppFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public enum Section: String, CaseIterable, Equatable {
            case library
            case settings
        }

        public var selectedSection: Section = .library
        public var library = LibraryFeature.State()
        public var settings = SettingsFeature.State()
        @Presents public var reader: ReaderFeature.State?
        public var startupFinished = false
        public var startupErrorMessage: String?

        public init() {}
    }

    public enum Action: Equatable {
        case onAppear
        case startupFinished
        case startupFailed(String)
        case selectedSectionChanged(State.Section)

        case library(LibraryFeature.Action)
        case settings(SettingsFeature.Action)
        case reader(PresentationAction<ReaderFeature.Action>)
        case closeReaderTapped
    }

    @Dependency(\.cloudSyncClient) var cloudSyncClient
    @Dependency(\.stowerRepository) var repository
    @Dependency(\.urlIngestionClient) var ingestionClient

    public var body: some ReducerOf<Self> {
        Scope(state: \.library, action: \.library) {
            LibraryFeature()
        }
        Scope(state: \.settings, action: \.settings) {
            SettingsFeature()
        }
        .ifLet(\.$reader, action: \.reader) {
            ReaderFeature()
        }

        Reduce { state, action in
            switch action {
            case .onAppear:
                let cloudSyncClient = self.cloudSyncClient
                let repository = self.repository
                let ingestionClient = self.ingestionClient
                return .run { send in
                    do {
                        try await cloudSyncClient.start()
                        try await processIngestionJobs(
                            repository: repository,
                            ingestionClient: ingestionClient
                        )
                        try await cloudSyncClient.sendChanges()
                        await send(.startupFinished)
                        await send(.library(.reload))
                        await send(.settings(.load))
                    } catch {
                        await send(.startupFailed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.startup, cancelInFlight: true)

            case .startupFinished:
                state.startupFinished = true
                state.startupErrorMessage = nil
                return .none

            case .startupFailed(let message):
                state.startupFinished = true
                state.startupErrorMessage = message
                return .none

            case .selectedSectionChanged(let section):
                state.selectedSection = section
                return .none

            case .library(.openItem(let id)):
                state.reader = ReaderFeature.State(itemID: id)
                return .none

            case .closeReaderTapped:
                state.reader = nil
                return .none

            case .library, .settings, .reader:
                return .none
            }
        }
    }

    enum CancelID {
        case startup
    }
}

private func processIngestionJobs(
    repository: StowerRepository,
    ingestionClient: URLIngestionClient
) async throws {
    let jobs = try await repository.fetchPendingIngestionJobs()
    for job in jobs {
        switch job.kind {
        case .url:
            let trimmed = job.payload.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed) {
                let result = try await ingestionClient.ingest(url)
                _ = try await repository.createItemFromIngestion(result)
            } else {
                _ = try await repository.createItemFromIngestion(.sharedText(trimmed))
            }
        case .text:
            _ = try await repository.createItemFromIngestion(.sharedText(job.payload))
        }
        try await repository.markIngestionJobProcessed(job.id)
    }
}
