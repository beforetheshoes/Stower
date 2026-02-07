import ComposableArchitecture

@Reducer
public struct SettingsFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var settings = ImageDownloadSettings()
        public var errorMessage: String?

        public init() {}
    }

    public enum Action: Equatable {
        case load
        case response(ImageDownloadSettings)
        case failed(String)
        case globalAutoDownloadChanged(Bool)
        case askForNewSourcesChanged(Bool)
        case save
        case saveFinished
        case saveFailed(String)
    }

    @Dependency(\.stowerRepository) var repository

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .load:
                let repository = self.repository
                return .run { send in
                    do {
                        let settings = try await repository.loadSettings()
                        await send(.response(settings))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .response(let settings):
                state.settings = settings
                state.errorMessage = nil
                return .none

            case .failed(let error):
                state.errorMessage = error
                return .none

            case .globalAutoDownloadChanged(let enabled):
                state.settings.globalAutoDownload = enabled
                return .send(.save)

            case .askForNewSourcesChanged(let enabled):
                state.settings.askForNewSources = enabled
                return .send(.save)

            case .save:
                let repository = self.repository
                return .run { [settings = state.settings] send in
                    do {
                        try await repository.saveSettings(settings)
                        await send(.saveFinished)
                    } catch {
                        await send(.saveFailed(error.localizedDescription))
                    }
                }

            case .saveFailed(let error):
                state.errorMessage = error
                return .none

            case .saveFinished:
                return .none
            }
        }
    }
}
