import Foundation
@testable import StowerFeature
import Testing

/// Tests here must run serialized because `StubProtocol` keeps a static
/// URL→response registry that would race under the default parallel runner.
@Suite(.serialized)
struct ArchiveServerFetchThroughTests {
    // MARK: - Metadata sidecar

    @Test
    func saveAndLoadOrigin_roundTrips() throws {
        let id = UUID()
        defer { AssetArchiver.deleteArchive(for: id) }

        let origin = URL(string: "https://example.com")!
        AssetArchiver.saveMetadata(origin: origin, for: id)

        let loaded = AssetArchiver.loadOriginURL(for: id)
        #expect(loaded == origin)
    }

    @Test
    func loadOrigin_missingMetadata_returnsNil() {
        let id = UUID()
        #expect(AssetArchiver.loadOriginURL(for: id) == nil)
    }

    // MARK: - Fetch-through

    @Test
    func fetchThrough_onSuccess_writesToDiskAndReturnsBytes() async throws {
        let id = UUID()
        let archiveDir = AssetArchiver.archiveDirectory(for: id)
        defer { AssetArchiver.deleteArchive(for: id) }
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let origin = URL(string: "https://stub.test")!
        let requestedPath = "/_next/static/chunks/abc123.js"
        let expectedBody = Data("console.log('hello from the network');".utf8)
        let destination = archiveDir.appendingPathComponent("_next/static/chunks/abc123.js")

        StubProtocol.reset()
        StubProtocol.register(
            url: "https://stub.test/_next/static/chunks/abc123.js",
            body: expectedBody
        )

        let session = makeStubSession()

        let result = await LocalArchiveServer.fetchThrough(
            path: requestedPath,
            origin: origin,
            destination: destination,
            session: session
        )

        #expect(result == expectedBody)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let written = try Data(contentsOf: destination)
        #expect(written == expectedBody)
    }

    @Test
    func fetchThrough_on404_returnsNilAndWritesNothing() async throws {
        let id = UUID()
        let archiveDir = AssetArchiver.archiveDirectory(for: id)
        defer { AssetArchiver.deleteArchive(for: id) }
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let origin = URL(string: "https://stub.test")!
        let destination = archiveDir.appendingPathComponent("api/get-metrics")

        StubProtocol.reset()
        StubProtocol.register(
            url: "https://stub.test/api/get-metrics",
            body: Data(),
            status: 404
        )

        let session = makeStubSession()

        let result = await LocalArchiveServer.fetchThrough(
            path: "/api/get-metrics",
            origin: origin,
            destination: destination,
            session: session
        )

        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func fetchThrough_preservesOriginOverDestinationPath() async throws {
        let id = UUID()
        let archiveDir = AssetArchiver.archiveDirectory(for: id)
        defer { AssetArchiver.deleteArchive(for: id) }
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        // Origin has its own path component — fetch-through should IGNORE
        // the origin's path and resolve the requested path against the root,
        // because WKWebView asks for "/foo.js" relative to localhost, and we
        // need "https://origin.test/foo.js", not "https://origin.test/blog/foo.js".
        let origin = URL(string: "https://origin.test/blog/article")!
        let destination = archiveDir.appendingPathComponent("foo.js")

        StubProtocol.reset()
        StubProtocol.register(url: "https://origin.test/foo.js", body: Data("ok".utf8))

        let session = makeStubSession()

        let result = await LocalArchiveServer.fetchThrough(
            path: "/foo.js",
            origin: origin,
            destination: destination,
            session: session
        )

        #expect(result == Data("ok".utf8))
    }

    // MARK: - Helpers

    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - URLProtocol stub

/// Lightweight URLProtocol that serves canned responses from a static registry.
/// Matches by exact URL string.
final class StubProtocol: URLProtocol {
    private struct StubbedResponse {
        var status: Int
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registry = [String: StubbedResponse]()

    static func reset() {
        lock.lock()
        registry.removeAll()
        lock.unlock()
    }

    static func register(url: String, body: Data, status: Int = 200) {
        lock.lock()
        registry[url] = StubbedResponse(status: status, body: body)
        lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url?.absoluteString else { return false }
        lock.lock()
        defer { lock.unlock() }
        return registry[url] != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let urlString = request.url?.absoluteString else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let stub = Self.registry[urlString]
        Self.lock.unlock()
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/javascript"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
