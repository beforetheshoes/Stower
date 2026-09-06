import Dependencies
import Foundation
import ImageIO
import StowerData
import UniformTypeIdentifiers

/// A finished export waiting to be handed to the share sheet or save panel.
public struct EPUBExportResult: Equatable, Sendable, Identifiable {
    public let itemID: UUID
    /// Lives in a per-export temp directory; `EPUBExportClient.discard`
    /// removes it once the user is done.
    public let fileURL: URL
    /// Base name without extension.
    public let suggestedFilename: String

    public var id: UUID { itemID }

    public init(itemID: UUID, fileURL: URL, suggestedFilename: String) {
        self.itemID = itemID
        self.fileURL = fileURL
        self.suggestedFilename = suggestedFilename
    }
}

public enum EPUBExportError: Error, Equatable, LocalizedError {
    case itemNotFound
    case notExportable
    case emptyDocument
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound:
            "The article could not be found."
        case .notExportable:
            "This item cannot be exported as an EPUB."
        case .emptyDocument:
            "The article has no reader content to export. Download it first if it has been offloaded."
        case .writeFailed(let reason):
            "The EPUB could not be written: \(reason)"
        }
    }
}

/// Builds a self-contained EPUB for one library item.
public struct EPUBExportClient: Sendable {
    public typealias Downloader = @Sendable (URL) async throws -> Data

    public var export: @Sendable (UUID) async throws -> EPUBExportResult
    /// Deletes the export's temp directory. Safe to call more than once.
    public var discard: @Sendable (URL) async -> Void

    public init(
        export: @escaping @Sendable (UUID) async throws -> EPUBExportResult,
        discard: @escaping @Sendable (URL) async -> Void
    ) {
        self.export = export
        self.discard = discard
    }
}

extension EPUBExportClient {
    public static let failing = EPUBExportClient(
        export: { _ in throw RepositoryError.notBootstrapped },
        discard: { _ in }
    )

    /// Real implementation. `download` is injectable so tests never touch
    /// the network.
    public static func live(download: @escaping Downloader = defaultDownload) -> EPUBExportClient {
        EPUBExportClient(
            export: { itemID in
                @Dependency(\.stowerRepository)
                var repository
                @Dependency(\.date)
                var date

                guard let item = try await repository.loadItem(itemID) else {
                    throw EPUBExportError.itemNotFound
                }
                guard item.isEPUBExportable else {
                    throw EPUBExportError.notExportable
                }
                guard let document = try await repository.loadReaderDocument(itemID),
                      !document.blocks.isEmpty
                else {
                    throw EPUBExportError.emptyDocument
                }

                let requests = EPUBImageCollector.requests(item: item, document: document)
                let images = await resolveImages(requests, download: download)
                try Task.checkCancellation()

                let package = EPUBBuilder.makePackage(
                    item: item,
                    document: document,
                    images: images,
                    modified: date.now
                )
                let fileURL = try writePackage(package, itemID: itemID)
                return EPUBExportResult(
                    itemID: itemID,
                    fileURL: fileURL,
                    suggestedFilename: package.suggestedFilename
                )
            },
            discard: { url in
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        )
    }

    // MARK: - Files

    static var exportsRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("StowerExports", isDirectory: true)
    }

    private static func writePackage(_ package: EPUBPackage, itemID: UUID) throws -> URL {
        let fileManager = FileManager.default
        let root = exportsRoot
        sweepStaleExports(in: root)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("\(package.suggestedFilename).epub")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try EPUBBuilder.write(package, to: fileURL)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw EPUBExportError.writeFailed(error.localizedDescription)
        }
        return fileURL
    }

    /// Exports the user never dismissed (a crash mid-share, say) would
    /// otherwise pile up in tmp. Anything older than a day goes.
    private static func sweepStaleExports(in root: URL) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for child in children {
            let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    // MARK: - Images

    private static let maxConcurrentImageLoads = 4

    static func resolveImages(
        _ requests: [EPUBImageRequest],
        download: @escaping Downloader
    ) async -> [String: EPUBImage] {
        await withTaskGroup(of: (String, EPUBImage?).self) { group in
            var results = [String: EPUBImage]()
            var pending = requests[...]
            var inFlight = 0

            func enqueue() {
                while inFlight < maxConcurrentImageLoads, let request = pending.popFirst() {
                    inFlight += 1
                    group.addTask {
                        (request.key, await resolveImage(request, download: download))
                    }
                }
            }

            enqueue()
            while let (key, image) = await group.next() {
                inFlight -= 1
                if let image {
                    results[key] = image
                }
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                enqueue()
            }
            return results
        }
    }

    private static func resolveImage(
        _ request: EPUBImageRequest,
        download: @escaping Downloader
    ) async -> EPUBImage? {
        var bytes: Data?
        if let localPath = request.localPath,
           FileManager.default.fileExists(atPath: localPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: localPath)) {
            bytes = data
        } else if let remote = request.remoteURL {
            bytes = try? await download(remote)
        }
        guard let bytes, !bytes.isEmpty,
              let format = EPUBImage.detectFormat(data: bytes, declaredMIMEType: request.declaredMIMEType)
        else { return nil }
        if format == .webp, let jpeg = transcodeToJPEG(bytes) {
            return EPUBImage(data: jpeg, format: .jpeg)
        }
        return EPUBImage(data: bytes, format: format)
    }

    /// WebP is legal in EPUB 3.3 but not every reader renders it. JPEG is.
    private static func transcodeToJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Network

    static let maxImageBytes = 10_000_000

    /// Shares the on-disk cache the library's thumbnails use, so a hero the
    /// user has already seen does not hit the network again.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            diskPath: "StowerImageCache"
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    public static let defaultDownload: Downloader = { url in
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= maxImageBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        return data
    }
}

// MARK: - Dependency

private enum EPUBExportClientKey: DependencyKey {
    static let liveValue = EPUBExportClient.live()
    static let testValue = EPUBExportClient.failing
}

extension DependencyValues {
    public var epubExportClient: EPUBExportClient {
        get { self[EPUBExportClientKey.self] }
        set { self[EPUBExportClientKey.self] = newValue }
    }
}
