import Dependencies
import Foundation
import StowerData
import SwiftSoup

/// Turns a recognized YouTube URL into a read-later article. Fetches oEmbed
/// metadata (title, author, thumbnail) plus the watch page HTML, extracts the
/// full video description, and builds a structured document consisting of a
/// tappable thumbnail card followed by the description rendered as paragraph
/// blocks. The thumbnail card links out to the canonical watch URL so the
/// reader's existing navigation decider opens it externally in the YouTube
/// app or Safari — no inline player.
///
/// The client follows the same closure-based injection pattern as
/// `URLIngestionClient` so tests can supply fixture fetch/download closures.
public struct YouTubeIngestionClient: Sendable {
    public var ingest: @Sendable (_ match: YouTubeURLDetector.Match, _ originalURL: URL) async throws -> IngestionResult

    public init(ingest: @escaping @Sendable (_ match: YouTubeURLDetector.Match, _ originalURL: URL) async throws -> IngestionResult) {
        self.ingest = ingest
    }

    /// Builds a client around injectable HTTP + image-download closures.
    /// `live` wires these to `URLSession.shared`; tests wire them to fixtures.
    /// Internal because the default `imageStorageDirectory` references an
    /// internal helper — the test target accesses this via `@testable import`.
    static func make(
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        downloadImage: @escaping @Sendable (URL) async throws -> Data,
        imageStorageDirectory: URL = MediaResolutionClient.imageStorageDirectory
    ) -> YouTubeIngestionClient {
        YouTubeIngestionClient { match, originalURL in
            try? FileManager.default.createDirectory(at: imageStorageDirectory, withIntermediateDirectories: true)

            // 1. Kick off oEmbed + HTML fetches in parallel. Either may fail;
            //    both failures still produce a usable minimal item.
            async let metadataTask = fetchOEmbed(videoID: match.videoID, fetch: fetch)
            async let htmlTask = fetchWatchPageHTML(videoID: match.videoID, fetch: fetch)
            let metadata = await metadataTask
            let html = await htmlTask

            // 2. Extract the full description from the watch page. Prefers
            //    `videoDetails.shortDescription` out of `ytInitialPlayerResponse`
            //    (the full text), falling back to the truncated `og:description`
            //    meta tag, and finally to nil.
            let description = extractDescription(fromHTML: html)

            // 3. Thumbnail caching. Prefer the oEmbed thumbnail; fall back to
            //    i.ytimg.com/vi/{id}/hqdefault.jpg.
            let remoteThumbnailURLString = metadata.thumbnailURL
                ?? YouTubeURLDetector.fallbackThumbnailURL(forID: match.videoID).absoluteString
            let posterLocalURL: String? = await cacheThumbnail(
                videoID: match.videoID,
                remoteURLString: remoteThumbnailURLString,
                directory: imageStorageDirectory,
                downloadImage: downloadImage
            )

            // 4. Build the MediaDescriptor used by the reader's thumbnail card.
            let canonicalWatchURL = YouTubeURLDetector.canonicalWatchURL(forID: match.videoID).absoluteString
            let descriptor = MediaDescriptor(
                kind: .video,
                sourceURL: canonicalWatchURL,
                localURL: nil,
                mimeType: "video/youtube",
                width: metadata.width,
                height: metadata.height,
                durationSeconds: nil,
                posterURL: remoteThumbnailURLString,
                caption: metadata.title,
                altText: metadata.title,
                providerName: "YouTube",
                providerVideoID: match.videoID,
                posterLocalURL: posterLocalURL,
                authorName: metadata.authorName
            )

            // 5. Compose the ReaderDocument: video card, then description
            //    paragraphs.
            // swiftlint:disable:next prefer_let_over_var
            var blocks: [ReaderBlock] = [.video(media: descriptor)]
            blocks.append(contentsOf: descriptionBlocks(description))

            let document = ReaderDocument(
                version: 1,
                sourceURL: originalURL.absoluteString,
                canonicalURL: canonicalWatchURL,
                title: metadata.title,
                blocks: blocks
            )

            let plainText: String
            if let description, !description.isEmpty {
                plainText = description
            } else {
                plainText = metadata.title
            }
            let excerpt: String = {
                let candidate = description?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let candidate, !candidate.isEmpty {
                    return String(candidate.prefix(220))
                }
                return metadata.title
            }()

            return IngestionResult(
                title: metadata.title,
                sourceURL: originalURL.absoluteString,
                canonicalURL: canonicalWatchURL,
                excerpt: excerpt,
                author: metadata.authorName,
                publishedAt: nil,
                siteName: "YouTube",
                heroImageURL: remoteThumbnailURLString,
                readingTimeMinutes: max(1, plainText.split(separator: " ").count / 225),
                hasRichMedia: true,
                renderFormat: .structuredV1,
                processingState: .ready,
                processingError: nil,
                document: document,
                plainText: plainText,
                media: [descriptor],
                embeds: [],
                sourceHTML: ""
            )
        }
    }

    public static let live: YouTubeIngestionClient = .make(
        fetch: { request in try await URLSession.shared.data(for: request) },
        downloadImage: { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            return data
        }
    )

    public static let failing = YouTubeIngestionClient { _, _ in
        throw URLError(.badURL)
    }
}

// MARK: - oEmbed

/// A normalized view of the fields we care about from YouTube's oEmbed
/// response, with sensible defaults when metadata is unavailable.
private struct YouTubeMetadata: Sendable {
    var title: String
    var authorName: String?
    var thumbnailURL: String?
    var width: Int?
    var height: Int?

    static let fallback = YouTubeMetadata(
        title: "YouTube video",
        authorName: nil,
        thumbnailURL: nil,
        width: nil,
        height: nil
    )
}

private struct YouTubeOEmbedResponse: Decodable {
    let title: String?
    let author_name: String?
    let author_url: String?
    let thumbnail_url: String?
    let provider_name: String?
    let width: Int?
    let height: Int?
}

/// Queries `https://www.youtube.com/oembed?url=…&format=json` and decodes the
/// response. Any thrown error, non-2xx status, or decode failure collapses to
/// `YouTubeMetadata.fallback` so the caller can still produce a usable item.
private func fetchOEmbed(
    videoID: String,
    fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
) async -> YouTubeMetadata {
    let watchURL = YouTubeURLDetector.canonicalWatchURL(forID: videoID).absoluteString
    guard let encoded = watchURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let endpoint = URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json") else {
        return .fallback
    }

    var request = URLRequest(url: endpoint)
    request.timeoutInterval = 15
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
        forHTTPHeaderField: "User-Agent"
    )
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .fallback
        }
        let decoded = try JSONDecoder().decode(YouTubeOEmbedResponse.self, from: data)
        let title = (decoded.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "YouTube video"
        return YouTubeMetadata(
            title: title,
            authorName: decoded.author_name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            thumbnailURL: decoded.thumbnail_url?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            width: decoded.width,
            height: decoded.height
        )
    } catch {
        return .fallback
    }
}

// MARK: - Watch page HTML + description extraction

/// Fetches the YouTube watch page HTML. Any failure returns nil so the caller
/// can gracefully produce an item without a description.
private func fetchWatchPageHTML(
    videoID: String,
    fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
) async -> String? {
    let url = YouTubeURLDetector.canonicalWatchURL(forID: videoID)
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
        forHTTPHeaderField: "User-Agent"
    )
    request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

    do {
        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        return String(bytes: data, encoding: .utf8)
    } catch {
        return nil
    }
}

/// Matches the structure of `ytInitialPlayerResponse` loosely enough that we
/// only decode the field we care about. Anything unexpected decodes to nil
/// without throwing because every field is Optional.
private struct YouTubePlayerResponse: Decodable {
    struct VideoDetails: Decodable {
        let shortDescription: String?
    }
    let videoDetails: VideoDetails?
}

/// Extracts the best-available description from a YouTube watch page HTML
/// string. Returns nil when nothing usable is present.
///
/// Strategy:
///   1. Try to pull the full description out of the `ytInitialPlayerResponse`
///      JavaScript object that YouTube embeds in a `<script>` tag. This has
///      the complete, untruncated `shortDescription` text.
///   2. Fall back to the `og:description` meta tag (short, truncated, but
///      reliable).
///   3. Give up.
///
/// Both code paths are best-effort — YouTube changes its markup frequently
/// and we silently fall through rather than throwing.
private func extractDescription(fromHTML html: String?) -> String? {
    guard let html else { return nil }

    // 1. ytInitialPlayerResponse scan.
    if let jsonString = extractBalancedJSONObject(from: html, afterMarker: "ytInitialPlayerResponse"),
       let data = jsonString.data(using: .utf8),
       let decoded = try? JSONDecoder().decode(YouTubePlayerResponse.self, from: data),
       let description = decoded.videoDetails?.shortDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
       !description.isEmpty {
        return description
    }

    // 2. og:description fallback via SwiftSoup.
    if let document = try? SwiftSoup.parse(html) {
        let selectors = [
            "meta[property=og:description]",
            "meta[name=description]",
            "meta[name=twitter:description]",
        ]
        for selector in selectors {
            if let element = try? document.select(selector).first(),
               let content = try? element.attr("content"),
               case let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                return trimmed
            }
        }
    }

    return nil
}

/// Scans `html` for the first `{`-delimited JavaScript object literal that
/// appears after `marker`, returning it as a JSON string. Tracks string
/// literals and escape sequences so that `{`/`}` characters inside quoted
/// strings do not throw off brace depth.
///
/// Fragile by design — it exists only to pull a single `shortDescription`
/// field out of YouTube's page-embedded JavaScript, and callers must fall
/// back gracefully when it returns nil.
private func extractBalancedJSONObject(from html: String, afterMarker marker: String) -> String? {
    guard let markerRange = html.range(of: marker) else { return nil }
    let tail = html[markerRange.upperBound...]
    guard let braceStart = tail.firstIndex(of: "{") else { return nil }

    var depth = 0
    var inString = false
    var escape = false
    var index = braceStart

    while index < tail.endIndex {
        let ch = tail[index]
        if escape {
            escape = false
        } else if ch == "\\" {
            escape = true
        } else if ch == "\"" {
            inString.toggle()
        } else if !inString {
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(tail[braceStart...index])
                }
            }
        }
        index = tail.index(after: index)
    }
    return nil
}

/// Splits a YouTube description into paragraph blocks.
///
/// Each non-empty line in the source becomes its own paragraph. This matches
/// how YouTube itself presents descriptions (every line break is meaningful —
/// chapter lists, timestamps, URL manifests) and avoids the prose-collapse
/// problem where mid-line breaks inside a single paragraph would disappear.
private func descriptionBlocks(_ description: String?) -> [ReaderBlock] {
    guard let description else { return [] }
    let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    return trimmed
        .split(omittingEmptySubsequences: false) { $0.isNewline }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { .paragraph([.text($0)]) }
}

// MARK: - Thumbnail caching

/// Downloads a thumbnail and persists it to the shared image storage
/// directory. Returns the local path on success, nil on any failure.
private func cacheThumbnail(
    videoID: String,
    remoteURLString: String,
    directory: URL,
    downloadImage: @Sendable (URL) async throws -> Data
) async -> String? {
    guard let remote = URL(string: remoteURLString),
          let scheme = remote.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
        return nil
    }
    do {
        let data = try await downloadImage(remote)
        guard !data.isEmpty else { return nil }
        let destination = directory.appendingPathComponent("yt-\(videoID).jpg")
        try data.write(to: destination, options: .atomic)
        return destination.path
    } catch {
        return nil
    }
}

// MARK: - Dependency Key

private enum YouTubeIngestionClientKey: DependencyKey {
    static let liveValue = YouTubeIngestionClient.live
    static let testValue = YouTubeIngestionClient.failing
}

extension DependencyValues {
    public var youTubeIngestionClient: YouTubeIngestionClient {
        get { self[YouTubeIngestionClientKey.self] }
        set { self[YouTubeIngestionClientKey.self] = newValue }
    }
}

// MARK: - String helpers

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
