import Dependencies
import Foundation

public enum ShareIngestionClient {
    public enum Error: Swift.Error, LocalizedError {
        case appGroupUnavailable

        public var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "The shared App Group container is not available. Reinstall the share extension."
            }
        }
    }

    public static func enqueueURL(_ url: URL) async throws {
        try await enqueueURL(url, repository: bootstrappedRepository())
    }

    public static func enqueueText(
        _ text: String,
        titleHint: String? = nil,
        mode: TextImportMode = .auto
    ) async throws {
        try await enqueueText(
            text,
            titleHint: titleHint,
            mode: mode,
            as: .text,
            repository: bootstrappedRepository()
        )
    }

    public static func enqueueMarkdown(_ markdown: String, titleHint: String? = nil) async throws {
        try await enqueueText(
            markdown,
            titleHint: titleHint,
            mode: .markdown,
            as: .markdown,
            repository: bootstrappedRepository()
        )
    }

    /// Copies a PDF into the shared App Group container and enqueues a `.pdf`
    /// job for it. See `stageAndEnqueue`.
    public static func enqueuePDF(_ sourceURL: URL) async throws {
        try await stageAndEnqueue(
            sourceURL,
            as: .pdf,
            repository: bootstrappedRepository(),
            container: appGroupContainer()
        )
    }

    /// Copies an EPUB into the shared App Group container and enqueues an
    /// `.epub` job for it. See `stageAndEnqueue`.
    public static func enqueueEPUB(_ sourceURL: URL) async throws {
        try await stageAndEnqueue(
            sourceURL,
            as: .epub,
            repository: bootstrappedRepository(),
            container: appGroupContainer()
        )
    }

    /// Copies a `.zip` website archive into the shared App Group container
    /// and enqueues a `.website` job for it. See `stageAndEnqueue`.
    public static func enqueueWebsiteZip(_ sourceURL: URL) async throws {
        try await stageAndEnqueue(
            sourceURL,
            as: .website,
            repository: bootstrappedRepository(),
            container: appGroupContainer()
        )
    }

    // MARK: - Implementation

    /// A file kind the extension can hand over, with where it is staged.
    enum StagedKind {
        case pdf
        case epub
        case website

        var jobKind: IngestionJob.Kind {
            switch self {
            case .pdf:
                .pdf
            case .epub:
                .epub
            case .website:
                .website
            }
        }

        var folder: String {
            switch self {
            case .pdf:
                "PendingPDFs"
            case .epub:
                "PendingEPUBs"
            case .website:
                "PendingWebsites"
            }
        }

        var fallbackFilename: String {
            switch self {
            case .pdf:
                "document.pdf"
            case .epub:
                "book.epub"
            case .website:
                "website.zip"
            }
        }
    }

    static func enqueueURL(_ url: URL, repository: StowerRepository) async throws {
        try await repository.enqueueIngestionJob(.url, url.absoluteString)
    }

    static func enqueueText(
        _ text: String,
        titleHint: String?,
        mode: TextImportMode,
        as jobKind: IngestionJob.Kind,
        repository: StowerRepository
    ) async throws {
        let payload = try QueuedTextPayloadCodec.encode(
            QueuedTextPayload(content: text, mode: mode, titleHint: titleHint)
        )
        try await repository.enqueueIngestionJob(jobKind, payload)
    }

    /// Copies the file at `sourceURL` into `container/{folder}/{uuid}/` and
    /// enqueues a job whose payload is the absolute destination path.
    ///
    /// The share extension's picker hands over a short-lived file URL that is
    /// removed as soon as its callback returns, so the file is copied (not
    /// moved) into long-lived storage before the main app drains the job.
    /// The source is left alone.
    ///
    /// The copy goes in a UUID-named subdirectory so the original filename
    /// survives: the ingesters use it as the title when the file carries
    /// none, and a file named after a UUID would title the item with one.
    static func stageAndEnqueue(
        _ sourceURL: URL,
        as kind: StagedKind,
        repository: StowerRepository,
        container: URL
    ) async throws {
        @Dependency(\.uuid)
        var uuid
        let pendingDir = container
            .appendingPathComponent(kind.folder, isDirectory: true)
            .appendingPathComponent(uuid().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let filename = sourceURL.lastPathComponent.isEmpty
            ? kind.fallbackFilename
            : sourceURL.lastPathComponent
        let destination = pendingDir.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        try await repository.enqueueIngestionJob(kind.jobKind, destination.path)
    }

    private static func bootstrappedRepository() throws -> StowerRepository {
        try prepareDependencies {
            // The share extension should avoid CloudKit work.
            try $0.bootstrapStowerDatabase(enableSync: false)
        }
        @Dependency(\.stowerRepository)
        var repository
        return repository
    }

    private static func appGroupContainer() throws -> URL {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: StowerDatabase.appGroupID)
        else {
            throw Error.appGroupUnavailable
        }
        return container
    }
}
