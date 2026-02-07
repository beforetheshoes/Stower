import Dependencies
import Foundation

public enum ShareIngestionClient {
    public static func enqueueURL(_ url: URL) throws {
        try prepareDependencies {
            try $0.bootstrapStowerDatabase()
        }
        @Dependency(\.stowerRepository) var repository
        Task {
            try? await repository.enqueueIngestionJob(.url, url.absoluteString)
        }
    }

    public static func enqueueText(_ text: String) throws {
        try prepareDependencies {
            try $0.bootstrapStowerDatabase()
        }
        @Dependency(\.stowerRepository) var repository
        Task {
            try? await repository.enqueueIngestionJob(.text, text)
        }
    }
}
