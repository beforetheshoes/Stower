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

    public static func enqueueURL(_ url: URL) throws {
        try prepareDependencies {
            // Share extension should avoid CloudKit work.
            try $0.bootstrapStowerDatabase(enableSync: false)
        }
        @Dependency(\.stowerRepository)
        var repository
        Task {
            try? await repository.enqueueIngestionJob(.url, url.absoluteString)
        }
    }

    public static func enqueueText(
        _ text: String,
        titleHint: String? = nil,
        mode: TextImportMode = .auto
    ) throws {
        try prepareDependencies {
            // Share extension should avoid CloudKit work.
            try $0.bootstrapStowerDatabase(enableSync: false)
        }
        @Dependency(\.stowerRepository)
        var repository
        let payload = try QueuedTextPayloadCodec.encode(
            QueuedTextPayload(
                content: text,
                mode: mode,
                titleHint: titleHint
            )
        )
        Task {
            try? await repository.enqueueIngestionJob(.text, payload)
        }
    }

    public static func enqueueMarkdown(_ markdown: String, titleHint: String? = nil) throws {
        try prepareDependencies {
            try $0.bootstrapStowerDatabase(enableSync: false)
        }
        @Dependency(\.stowerRepository)
        var repository
        let payload = try QueuedTextPayloadCodec.encode(
            QueuedTextPayload(
                content: markdown,
                mode: .markdown,
                titleHint: titleHint
            )
        )
        Task {
            try? await repository.enqueueIngestionJob(.markdown, payload)
        }
    }

    /// Copies a PDF at `sourceURL` into the shared App Group container under
    /// `PendingPDFs/{uuid}.pdf` and enqueues a `.pdf` ingestion job whose
    /// payload is the absolute destination path. The share extension's picker
    /// callback hands us a short-lived file URL that is removed as soon as
    /// the callback returns, so we must copy (not move) into long-lived
    /// storage before the job is drained by the main app. The source file is
    /// not deleted — the caller is responsible for cleaning up any scratch
    /// copies it made itself.
    public static func enqueuePDF(_ sourceURL: URL) throws {
        try prepareDependencies {
            try $0.bootstrapStowerDatabase(enableSync: false)
        }

        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: StowerDatabase.appGroupID)
        else {
            throw Error.appGroupUnavailable
        }

        // Use a UUID-named subdirectory so we can preserve the original
        // filename. `PDFIngestionClient.live` uses the file URL's
        // `lastPathComponent` as the title fallback when the PDF has no
        // embedded title attribute, so writing to `PendingPDFs/{uuid}.pdf`
        // would produce items titled with a raw UUID in the library.
        let pendingRoot = container.appendingPathComponent("PendingPDFs", isDirectory: true)
        let pendingDir = pendingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: pendingDir,
            withIntermediateDirectories: true
        )
        let filename = sourceURL.lastPathComponent.isEmpty
            ? "document.pdf"
            : sourceURL.lastPathComponent
        let destination = pendingDir.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        @Dependency(\.stowerRepository)
        var repository
        let path = destination.path
        Task {
            try? await repository.enqueueIngestionJob(.pdf, path)
        }
    }

    /// Copies a `.zip` website archive at `sourceURL` into the shared App
    /// Group container under `PendingWebsites/{uuid}/` and enqueues a
    /// `.website` ingestion job whose payload is the absolute destination
    /// path. Mirrors `enqueuePDF` so the main-app ingester can rely on the
    /// original filename for the title fallback before the `<title>` tag has
    /// been parsed out of index.html.
    public static func enqueueWebsiteZip(_ sourceURL: URL) throws {
        try prepareDependencies {
            try $0.bootstrapStowerDatabase(enableSync: false)
        }

        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: StowerDatabase.appGroupID)
        else {
            throw Error.appGroupUnavailable
        }

        let pendingRoot = container.appendingPathComponent("PendingWebsites", isDirectory: true)
        let pendingDir = pendingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: pendingDir,
            withIntermediateDirectories: true
        )
        let filename = sourceURL.lastPathComponent.isEmpty
            ? "website.zip"
            : sourceURL.lastPathComponent
        let destination = pendingDir.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        @Dependency(\.stowerRepository)
        var repository
        let path = destination.path
        Task {
            try? await repository.enqueueIngestionJob(.website, path)
        }
    }
}
