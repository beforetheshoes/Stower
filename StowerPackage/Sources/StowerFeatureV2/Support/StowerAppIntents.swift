import AppIntents
import Dependencies
import Foundation
import StowerData

public struct AppIntentIngestionClient: Sendable {
    public var enqueueURL: @Sendable (URL) async throws -> Void
    public var enqueueText: @Sendable (String) async throws -> Void

    public init(
        enqueueURL: @escaping @Sendable (URL) async throws -> Void,
        enqueueText: @escaping @Sendable (String) async throws -> Void
    ) {
        self.enqueueURL = enqueueURL
        self.enqueueText = enqueueText
    }
}

private enum AppIntentIngestionClientKey: DependencyKey {
    static let liveValue = AppIntentIngestionClient(
        enqueueURL: { url in
            try prepareDependencies {
                try $0.bootstrapStowerDatabase(enableSync: false)
            }
            @Dependency(\.stowerRepository)
            var repository
            try await repository.enqueueIngestionJob(.url, url.absoluteString)
        },
        enqueueText: { text in
            try prepareDependencies {
                try $0.bootstrapStowerDatabase(enableSync: false)
            }
            @Dependency(\.stowerRepository)
            var repository
            let payload = try QueuedTextPayloadCodec.encode(
                QueuedTextPayload(content: text, mode: .auto)
            )
            try await repository.enqueueIngestionJob(.text, payload)
        }
    )

    static let testValue = AppIntentIngestionClient(
        enqueueURL: { _ in },
        enqueueText: { _ in }
    )
}

extension DependencyValues {
    public var appIntentIngestionClient: AppIntentIngestionClient {
        get { self[AppIntentIngestionClientKey.self] }
        set { self[AppIntentIngestionClientKey.self] = newValue }
    }
}

private func currentAppIntentIngestionClient() -> AppIntentIngestionClient {
    @Dependency(\.appIntentIngestionClient)
    var ingestion
    return ingestion
}

public enum StowerIntentError: LocalizedError {
    case invalidURL
    case emptyText

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Stower can save only HTTP or HTTPS URLs."
        case .emptyText:
            "Enter some text to save to Stower."
        }
    }
}

public struct SaveURLToStowerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Save URL to Stower"
    public static let description = IntentDescription("Adds a web page to your Stower reading queue.")
    public static let openAppWhenRun = false

    @Parameter(title: "URL")
    public var url: URL

    public init() {}

    public init(url: URL) {
        self.url = url
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw StowerIntentError.invalidURL
        }
        let ingestion = currentAppIntentIngestionClient()
        try await ingestion.enqueueURL(url)
        return .result(dialog: "Saved to Stower.")
    }
}

public struct SaveTextToStowerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Save Text to Stower"
    public static let description = IntentDescription("Adds text to your Stower reading queue.")
    public static let openAppWhenRun = false

    @Parameter(title: "Text")
    public var text: String

    public init() {}

    public init(text: String) {
        self.text = text
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StowerIntentError.emptyText }
        let ingestion = currentAppIntentIngestionClient()
        try await ingestion.enqueueText(trimmed)
        return .result(dialog: "Saved to Stower.")
    }
}

public struct StowerAppShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveURLToStowerIntent(),
            phrases: [
                "Save a URL to \(.applicationName)",
                "Add a link to \(.applicationName)",
            ],
            shortTitle: "Save URL",
            systemImageName: "link.badge.plus"
        )
        AppShortcut(
            intent: SaveTextToStowerIntent(),
            phrases: [
                "Save text to \(.applicationName)",
                "Add text to \(.applicationName)",
            ],
            shortTitle: "Save Text",
            systemImageName: "text.badge.plus"
        )
    }
}
