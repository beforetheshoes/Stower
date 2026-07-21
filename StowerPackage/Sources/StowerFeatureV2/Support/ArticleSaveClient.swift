import Dependencies
import Foundation
import StowerData

public struct ArticleSaveResult: Equatable, Sendable {
    public let item: SavedItem
    public let state: ProcessingState
    public let warnings: [String]

    public init(item: SavedItem, state: ProcessingState, warnings: [String] = []) {
        self.item = item
        self.state = state
        self.warnings = warnings
    }
}

/// The single transaction boundary for URL saves, refreshes and hydration.
/// Native capture packages are verified and atomically installed before the
/// local capture version is exposed to Reader View.
public struct ArticleSaveClient: Sendable {
    public var save: @Sendable (URL) async throws -> ArticleSaveResult
    public var refresh: @Sendable (UUID, URL) async throws -> ArticleSaveResult
    public var hydrate: @Sendable (UUID, URL) async throws -> ArticleSaveResult

    public init(
        save: @escaping @Sendable (URL) async throws -> ArticleSaveResult,
        refresh: @escaping @Sendable (UUID, URL) async throws -> ArticleSaveResult,
        hydrate: @escaping @Sendable (UUID, URL) async throws -> ArticleSaveResult
    ) {
        self.save = save
        self.refresh = refresh
        self.hydrate = hydrate
    }

    public static let failing = ArticleSaveClient(
        save: { _ in throw RepositoryError.notBootstrapped },
        refresh: { _, _ in throw RepositoryError.notBootstrapped },
        hydrate: { _, _ in throw RepositoryError.notBootstrapped }
    )

    public static let live = ArticleSaveClient(
        save: { url in
            @Dependency(\.stowerRepository) var repository
            @Dependency(\.urlIngestionClient) var ingestionClient
            let result = try await ingestionClient.ingest(url)
            try Task.checkCancellation()
            let item = try await repository.createItemFromIngestion(result)
            return try await finish(result: result, item: item, repository: repository)
        },
        refresh: { itemID, url in
            @Dependency(\.stowerRepository) var repository
            @Dependency(\.urlIngestionClient) var ingestionClient
            let result = try await ingestionClient.ingest(url)
            try Task.checkCancellation()
            guard let item = try await repository.updateItemFromIngestion(itemID, result) else {
                throw ArticleSaveError.itemNoLongerExists
            }
            return try await finish(result: result, item: item, repository: repository)
        },
        hydrate: { itemID, url in
            @Dependency(\.stowerRepository) var repository

            // Exact synced bytes always win. A source refetch is reserved for
            // legacy rows with no capture manifest.
            if let synced = try await repository.loadArticleCapture(itemID) {
                let packageData = try ArticleCapturePackage.reconstruct(synced)
                try ArticleCapturePackage.install(
                    packageData: packageData,
                    expectedHash: synced.manifest.sha256,
                    expectedCaptureID: synced.manifest.captureID,
                    for: itemID
                )
                try await repository.markArticleCaptureInstalled(
                    itemID,
                    synced.manifest.captureID,
                    synced.manifest.version
                )
                guard let item = try await repository.loadItem(itemID) else {
                    throw ArticleSaveError.itemNoLongerExists
                }
                let metadata = ArticleCapturePackage.metadata(for: itemID)
                return ArticleSaveResult(
                    item: item,
                    state: metadata?.completeness == .partial ? .partial : .ready,
                    warnings: metadata?.warnings ?? []
                )
            }

            @Dependency(\.urlIngestionClient) var ingestionClient
            let result = try await ingestionClient.ingest(url)
            try Task.checkCancellation()
            try await repository.hydrateItemContent(itemID, result)
            guard let item = try await repository.loadItem(itemID) else {
                throw ArticleSaveError.itemNoLongerExists
            }
            return try await finish(result: result, item: item, repository: repository)
        }
    )

    private static func finish(
        result: IngestionResult,
        item: SavedItem,
        repository: StowerRepository
    ) async throws -> ArticleSaveResult {
        if let artifact = result.webCapture {
            defer { try? FileManager.default.removeItem(at: artifact.stagedPackageURL.deletingLastPathComponent()) }
            let (manifest, chunks) = try ArticleCapturePackage.makeChunks(from: artifact, itemID: item.id)
            try Task.checkCancellation()
            try await repository.saveArticleCapture(manifest, chunks)
            try Task.checkCancellation()
            try ArticleCapturePackage.install(artifact, for: item.id)
            try await repository.markArticleCaptureInstalled(item.id, artifact.captureID, artifact.version)
            let installedItem = try await repository.loadItem(item.id) ?? item
            return ArticleSaveResult(
                item: installedItem,
                state: result.processingState,
                warnings: artifact.warnings
            )
        }

        // Preserve the existing non-HTML short circuits and imported/legacy
        // behaviors while new ordinary web articles use native captures.
        if result.renderFormat == .pdf, let hash = result.pdfSHA256 {
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("stower-pdf-stage-\(hash).pdf")
            if FileManager.default.fileExists(atPath: staged.path) {
                try PDFArchiver.archivePDF(from: staged, itemID: item.id)
                try? FileManager.default.removeItem(at: staged)
            }
        } else if result.renderFormat == .webView,
                  !result.sourceHTML.isEmpty,
                  let source = result.sourceURL,
                  let baseURL = URL(string: source) {
            await AssetArchiver.archiveAssets(html: result.sourceHTML, baseURL: baseURL, itemID: item.id)
        }
        return ArticleSaveResult(item: item, state: result.processingState)
    }
}

public enum ArticleSaveError: Error, LocalizedError, Equatable {
    case itemNoLongerExists

    public var errorDescription: String? {
        switch self {
        case .itemNoLongerExists: "This saved item no longer exists."
        }
    }
}

private enum ArticleSaveClientKey: DependencyKey {
    static let liveValue = ArticleSaveClient.live
    // Preserve dependency overrides used by reducer tests: the live wrapper
    // resolves its repository/ingester lazily from the current test context.
    static let testValue = ArticleSaveClient.live
}

extension DependencyValues {
    public var articleSaveClient: ArticleSaveClient {
        get { self[ArticleSaveClientKey.self] }
        set { self[ArticleSaveClientKey.self] = newValue }
    }
}
