import Foundation
import Network

/// A lightweight local HTTP server that serves archived web content from disk.
///
/// Serves files from an archive directory over `http://localhost:{port}/`. This allows
/// WKWebView to load archived pages with full HTTP semantics — absolute paths resolve
/// correctly, ES modules work, and `window.location` reflects the original URL structure.
///
/// When a request matches the article's original path (e.g., `/blog/quantization`),
/// the server responds with `index.html`. All other paths are mapped directly to files
/// in the archive directory.
///
/// **Fetch-through**: Regex-based pre-archiving can never catch every asset a modern
/// SPA references — e.g. Next.js assembles `_next/static/chunks/*.js` URLs at runtime
/// from an embedded manifest, so static analysis sees only the template, not the full
/// chunk names. To fill those gaps, the server falls back to live-fetching missing
/// assets from `originURL` on the first request and writing them to disk, so the
/// archive self-heals as the user interacts with the page.
final class LocalArchiveServer: @unchecked Sendable {
    private var listener: NWListener?
    private let archiveDir: URL
    private let articlePath: String
    /// Origin URL used to resolve relative paths when falling back to live fetch.
    /// Nil disables fetch-through entirely (pure offline mode).
    private let originURL: URL?
    private let queue = DispatchQueue(label: "LocalArchiveServer", qos: .userInitiated)
    private(set) var port: UInt16 = 0

    /// - Parameters:
    ///   - archiveDir: The directory containing the archived files.
    ///   - articlePath: The original URL path (e.g., "/blog/quantization").
    ///     Requests to this path serve index.html.
    ///   - originURL: The original site origin (scheme + host). When provided,
    ///     missing assets are fetched live and written to the archive.
    init(archiveDir: URL, articlePath: String, originURL: URL? = nil) {
        self.archiveDir = archiveDir
        self.articlePath = articlePath
        self.originURL = originURL
    }

    /// Starts the server on a random available port. Returns the port number.
    /// Uses async/await instead of blocking the calling thread with a semaphore.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        let archiveDir = self.archiveDir
        let articlePath = self.articlePath
        let originURL = self.originURL

        listener.newConnectionHandler = { [queue] connection in
            Self.handleConnection(
                connection,
                archiveDir: archiveDir,
                articlePath: articlePath,
                originURL: originURL,
                queue: queue
            )
        }

        let assignedPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port {
                        continuation.resume(returning: port.rawValue)
                    } else {
                        continuation.resume(throwing: ServerError.noPort)
                    }
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        self.port = assignedPort
        return assignedPort
    }

    enum ServerError: Error {
        case noPort
    }

    /// Stops the server.
    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    deinit {
        listener?.cancel()
    }

    // MARK: - Connection Handling

    private static func handleConnection(
        _ connection: NWConnection,
        archiveDir: URL,
        articlePath: String,
        originURL: URL?,
        queue: DispatchQueue
    ) {
        connection.start(queue: queue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
            guard let data, error == nil else {
                connection.cancel()
                return
            }

            let requestString = String(bytes: data, encoding: .utf8) ?? ""

            guard let firstLine = requestString.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }

            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }

            let method = String(parts[0])
            let rawPath = String(parts[1])
            let decodedPath = rawPath.components(separatedBy: "?").first?
                .removingPercentEncoding ?? rawPath

            // Resolve path → local file URL.
            let fileURL: URL
            let normalizedArticlePath = articlePath.hasSuffix("/")
                ? String(articlePath.dropLast())
                : articlePath
            let normalizedRequest = decodedPath.hasSuffix("/")
                ? String(decodedPath.dropLast())
                : decodedPath

            if normalizedRequest == normalizedArticlePath
                || normalizedRequest.isEmpty
                || normalizedRequest == "/" {
                fileURL = archiveDir.appendingPathComponent("index.html")
            } else {
                let relativePath = String(decodedPath.dropFirst())
                fileURL = archiveDir.appendingPathComponent(relativePath)
            }

            // Fast path: file already exists on disk.
            if FileManager.default.fileExists(atPath: fileURL.path),
               let fileData = try? Data(contentsOf: fileURL) {
                Self.sendOK(connection: connection, data: fileData, pathExtension: fileURL.pathExtension)
                return
            }

            // Miss: fetch-through if enabled and we have a reasonable assumption this is a GET for an asset.
            let canFetchThrough = originURL != nil
                && method.uppercased() == "GET"
                && decodedPath.hasPrefix("/")

            if canFetchThrough, let originURL {
                Task.detached {
                    if let fetched = await Self.fetchThrough(
                        path: decodedPath,
                        origin: originURL,
                        destination: fileURL
                    ) {
                        Self.sendOK(
                            connection: connection,
                            data: fetched,
                            pathExtension: fileURL.pathExtension
                        )
                    } else {
                        Self.send404(connection: connection, path: decodedPath, fileURL: fileURL)
                    }
                }
                return
            }

            Self.send404(connection: connection, path: decodedPath, fileURL: fileURL)
        }
    }

    // MARK: - Responses

    private static func sendOK(
        connection: NWConnection,
        data: Data,
        pathExtension: String
    ) {
        let mimeType = Self.mimeType(for: pathExtension)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(mimeType)\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(data)
        connection.send(
            content: responseData,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private static func send404(
        connection: NWConnection,
        path: String,
        fileURL: URL
    ) {
        // swiftlint:disable:next no_print_statements
        print("[ArchiveServer] 404: \(path) → \(fileURL.path)")
        let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    // MARK: - Fetch-through

    /// Live-fetches the given path from the origin, writes it to disk, and returns the bytes.
    /// Returns nil on any error so the caller can fall back to a 404.
    ///
    /// Exposed at `internal` visibility so tests can exercise it with a stubbed
    /// `URLSession` via a URLProtocol.
    static func fetchThrough(
        path: String,
        origin: URL,
        destination: URL,
        session: URLSession = .shared
    ) async -> Data? {
        // Resolve the request path against the origin, preserving scheme/host/port.
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let absoluteURL = components.url else { return nil }

        var request = URLRequest(url: absoluteURL)
        request.timeoutInterval = 15
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count < 20_000_000 else {
                return nil
            }

            // Persist so subsequent offline loads find it locally.
            let parent = destination.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            try? data.write(to: destination)
            // swiftlint:disable:next no_print_statements
            print("[ArchiveServer] fetched-through: \(path)")
            return data
        } catch {
            return nil
        }
    }

    // MARK: - MIME Types

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "js", "mjs":
            return "application/javascript; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "json":
            return "application/json; charset=utf-8"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "avif":
            return "image/avif"
        case "ico":
            return "image/x-icon"
        case "woff":
            return "font/woff"
        case "woff2":
            return "font/woff2"
        case "ttf":
            return "font/ttf"
        case "otf":
            return "font/otf"
        case "eot":
            return "application/vnd.ms-fontobject"
        case "map":
            return "application/json"
        case "xml":
            return "application/xml"
        case "txt":
            return "text/plain"
        default:
            return "application/octet-stream"
        }
    }
}
