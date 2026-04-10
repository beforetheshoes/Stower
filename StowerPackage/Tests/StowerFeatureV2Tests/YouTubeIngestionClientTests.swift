import Foundation
import Testing
@testable import StowerFeature
import StowerData

@Suite
struct YouTubeIngestionClientTests {

    private static let videoID = "dQw4w9WgXcQ"
    private static let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!

    private static let oembedJSON = #"""
    {
      "title": "Never Gonna Give You Up",
      "author_name": "Rick Astley",
      "author_url": "https://www.youtube.com/@RickAstleyYT",
      "thumbnail_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
      "provider_name": "YouTube",
      "width": 480,
      "height": 270
    }
    """#

    /// HTML fixture containing:
    ///   - an `og:description` meta tag (short fallback)
    ///   - a `ytInitialPlayerResponse` script with a multi-paragraph
    ///     `shortDescription`, which the extractor should prefer
    private static let watchPageHTML = ##"""
    <html>
      <head>
        <meta property="og:description" content="Short og description."/>
      </head>
      <body>
        <script>
          var ytInitialPlayerResponse = {"videoDetails":{"shortDescription":"First paragraph of the full description.\nSecond paragraph — still meaningful.\nThird paragraph with more detail."}};
        </script>
      </body>
    </html>
    """##

    /// Same shape but with `ytInitialPlayerResponse` missing — exercises the
    /// og:description fallback path.
    private static let watchPageHTMLWithoutPlayerResponse = ##"""
    <html>
      <head>
        <meta property="og:description" content="Falls back to og description."/>
      </head>
      <body></body>
    </html>
    """##

    /// Unique scratch directory for cached thumbnails so tests do not clobber
    /// each other or the real Documents/StowerImages folder.
    private static func makeScratchDirectory() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("stower-yt-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func makeHTTPResponse(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    /// Routes the two fetch kinds (oEmbed and watch page) to fixture data.
    /// Returns 404 for anything else so a regression would surface loudly.
    private static func makeFetch(
        oembedBody: String?,
        oembedStatus: Int = 200,
        watchBody: String?,
        watchStatus: Int = 200
    ) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            let urlString = request.url?.absoluteString ?? ""
            if urlString.contains("oembed") {
                let data = oembedBody.map { Data($0.utf8) } ?? Data()
                return (data, makeHTTPResponse(url: request.url!, status: oembedStatus))
            }
            if urlString.contains("/watch") {
                let data = watchBody.map { Data($0.utf8) } ?? Data()
                return (data, makeHTTPResponse(url: request.url!, status: watchStatus))
            }
            return (Data(), makeHTTPResponse(url: request.url!, status: 404))
        }
    }

    // MARK: - Happy path

    @Test
    func ingestPopulatesMetadataCachesThumbnailAndParsesFullDescription() async throws {
        let scratch = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let fakeJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        let client = YouTubeIngestionClient.make(
            fetch: Self.makeFetch(oembedBody: Self.oembedJSON, watchBody: Self.watchPageHTML),
            downloadImage: { _ in fakeJPEG },
            imageStorageDirectory: scratch
        )

        let match = YouTubeURLDetector.Match(videoID: Self.videoID, form: .watch)
        let result = try await client.ingest(match, Self.watchURL)

        #expect(result.title == "Never Gonna Give You Up")
        #expect(result.author == "Rick Astley")
        #expect(result.siteName == "YouTube")
        #expect(result.heroImageURL == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        #expect(result.processingState == .ready)
        #expect(result.renderFormat == .structuredV1)
        #expect(result.hasRichMedia)

        // Excerpt is the start of the full description, not the title.
        #expect(result.excerpt?.hasPrefix("First paragraph") == true)
        #expect(result.plainText.contains("First paragraph"))
        #expect(result.plainText.contains("Third paragraph"))

        // Media descriptor is well-formed.
        #expect(result.media.count == 1)
        let descriptor = try #require(result.media.first)
        #expect(descriptor.kind == .video)
        #expect(descriptor.providerName == "YouTube")
        #expect(descriptor.providerVideoID == Self.videoID)
        #expect(descriptor.authorName == "Rick Astley")
        #expect(descriptor.caption == "Never Gonna Give You Up")

        // Thumbnail was cached under the scratch directory.
        let posterLocal = try #require(descriptor.posterLocalURL)
        #expect(posterLocal.hasSuffix("yt-\(Self.videoID).jpg"))
        #expect(FileManager.default.fileExists(atPath: posterLocal))

        // Document structure: first block is the video card, followed by one
        // paragraph per non-empty line of the description.
        let blocks = result.document.blocks
        #expect(blocks.count == 4)
        if case .video = blocks[0] {} else {
            Issue.record("expected first block to be .video")
        }
        let paragraphTexts: [String] = blocks.dropFirst().compactMap { block in
            guard case let .paragraph(inlines) = block else { return nil }
            return inlines.compactMap { inline in
                if case let .text(value) = inline { return value } else { return nil }
            }.joined()
        }
        #expect(paragraphTexts == [
            "First paragraph of the full description.",
            "Second paragraph — still meaningful.",
            "Third paragraph with more detail.",
        ])
    }

    // MARK: - Falls back to og:description when ytInitialPlayerResponse is absent

    @Test
    func ingestFallsBackToOgDescriptionWhenPlayerResponseMissing() async throws {
        let scratch = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let client = YouTubeIngestionClient.make(
            fetch: Self.makeFetch(
                oembedBody: Self.oembedJSON,
                watchBody: Self.watchPageHTMLWithoutPlayerResponse
            ),
            downloadImage: { _ in Data([0xFF, 0xD8, 0xFF]) },
            imageStorageDirectory: scratch
        )

        let match = YouTubeURLDetector.Match(videoID: Self.videoID, form: .watch)
        let result = try await client.ingest(match, Self.watchURL)

        #expect(result.title == "Never Gonna Give You Up")
        // og:description becomes the only description paragraph.
        let blocks = result.document.blocks
        #expect(blocks.count == 2)
        if case let .paragraph(inlines) = blocks[1],
           case let .text(text) = inlines.first {
            #expect(text == "Falls back to og description.")
        } else {
            Issue.record("expected paragraph block with og description")
        }
    }

    // MARK: - Both oEmbed and HTML fail → minimal viable item

    @Test
    func ingestFallsBackToMinimalResultWhenBothFetchesThrow() async throws {
        let scratch = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let client = YouTubeIngestionClient.make(
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            downloadImage: { _ in throw URLError(.notConnectedToInternet) },
            imageStorageDirectory: scratch
        )

        let match = YouTubeURLDetector.Match(videoID: Self.videoID, form: .watch)
        let result = try await client.ingest(match, Self.watchURL)

        #expect(result.title == "YouTube video")
        #expect(result.author == nil)
        #expect(result.processingState == .ready)
        #expect(result.renderFormat == .structuredV1)

        // A single video-card block with the fallback poster URL; no
        // description paragraphs because the watch page was unreachable.
        #expect(result.document.blocks.count == 1)
        let descriptor = try #require(result.media.first)
        #expect(descriptor.providerVideoID == Self.videoID)
        #expect(descriptor.providerName == "YouTube")
        #expect(descriptor.posterLocalURL == nil)
        #expect(descriptor.posterURL == "https://i.ytimg.com/vi/\(Self.videoID)/hqdefault.jpg")
    }

    // MARK: - oEmbed 401 still resolves via HTML path

    @Test
    func ingestStillSucceedsWhenOEmbedReturns401() async throws {
        let scratch = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let client = YouTubeIngestionClient.make(
            fetch: Self.makeFetch(
                oembedBody: "",
                oembedStatus: 401,
                watchBody: Self.watchPageHTMLWithoutPlayerResponse
            ),
            downloadImage: { _ in Data([0xFF, 0xD8, 0xFF]) },
            imageStorageDirectory: scratch
        )

        let match = YouTubeURLDetector.Match(videoID: Self.videoID, form: .watch)
        let result = try await client.ingest(match, Self.watchURL)

        // Falls back to "YouTube video" from oEmbed, but the HTML
        // description still populated a paragraph block.
        #expect(result.title == "YouTube video")
        #expect(result.document.blocks.count >= 2)
    }
}
