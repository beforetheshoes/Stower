import Dependencies
import Foundation
import SwiftSoup

public enum URLIngestionError: Error, LocalizedError {
    case noExtractableContent

    public var errorDescription: String? {
        switch self {
        case .noExtractableContent:
            return "Couldn't extract any readable content from this page. It may require a login, rely on client-side rendering, or be blocked by a bot check."
        }
    }
}

public struct URLIngestionClient: Sendable {
    public var ingest: @Sendable (URL) async throws -> IngestionResult

    public init(ingest: @escaping @Sendable (URL) async throws -> IngestionResult) {
        self.ingest = ingest
    }

    public static let failing = URLIngestionClient { _ in
        throw URLError(.badURL)
    }

    public static let live = URLIngestionClient { url in
        // Short-circuit for YouTube URLs. The watch page is a JS shell with no
        // article-extractable content, so we bypass the HTML fetch entirely
        // and build the ingestion result from oEmbed metadata + a cached
        // thumbnail. See YouTubeIngestionClient for details.
        if let match = YouTubeURLDetector.match(url) {
            return try await YouTubeIngestionClient.live.ingest(match, url)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(decoding: data, as: UTF8.self)

        var result = try await ExtractionPipelineClient.live.extract(html, url)
        result.media = try await MediaResolutionClient.live.resolve(result.media)
        result.hasRichMedia = !result.media.isEmpty || !result.embeds.isEmpty

        // Store raw HTML. For webView format, the raw HTML preserves original
        // asset references that the OfflineSchemeHandler can serve from the local archive.
        // HTMLAssetInliner is not needed when using the scheme handler approach.
        result.sourceHTML = html
        return result
    }
}

public struct ExtractionPipelineClient: Sendable {
    public var extract: @Sendable (_ html: String, _ sourceURL: URL) async throws -> IngestionResult

    public init(extract: @escaping @Sendable (_ html: String, _ sourceURL: URL) async throws -> IngestionResult) {
        self.extract = extract
    }

    public static let live = ExtractionPipelineClient { html, sourceURL in
        let document = try SwiftSoup.parse(html, sourceURL.absoluteString)
        let title = try extractTitle(document: document, sourceURL: sourceURL)
        let canonicalURL = nonEmpty(try? document.select("link[rel=canonical]").first()?.attr("abs:href"))

        // Detect interactive content BEFORE stripping SVGs/scripts.
        let hasInteractiveContent = detectInteractiveContent(document: document)

        let root = try chooseRoot(document: document)
        let parsed = try parseBlocks(root: root, baseURL: sourceURL)
        let cleanedBlocks = sanitizeBlocks(parsed.blocks)
        let finalBlocks = cleanedBlocks.isEmpty ? parsed.blocks : cleanedBlocks

        let plainText = plainTextFromBlocks(finalBlocks)
        let excerpt = plainText.isEmpty ? nil : String(plainText.prefix(220))

        let author = nonEmpty(try? document.select("meta[name=author]").first()?.attr("content"))
            ?? nonEmpty(try? document.select("meta[property=article:author]").first()?.attr("content"))

        let siteName = nonEmpty(try? document.select("meta[property=og:site_name]").first()?.attr("content"))
            ?? sourceURL.host

        let heroImageURL = nonEmpty(try? document.select("meta[property=og:image]").first()?.attr("abs:content"))
            ?? nonEmpty(try? document.select("meta[name=twitter:image]").first()?.attr("abs:content"))
            ?? parsed.media.first(where: { $0.kind == .image })?.sourceURL

        let publishedRaw = nonEmpty(try? document.select("meta[property=article:published_time]").first()?.attr("content"))
            ?? nonEmpty(try? document.select("meta[name=date]").first()?.attr("content"))

        let oEmbeds = try discoverOEmbeds(document: document)
        let allEmbeds = dedupeEmbeds(parsed.embeds + oEmbeds)

        // If the parser came back with nothing at all — no blocks, no plain
        // text, and no interactive content — the fetch either hit a JS shell
        // we can't see into, a bot wall, or a genuinely empty page. Either
        // way there's nothing to show in the reader, so surface it as a
        // failure instead of storing an "available" row with an empty body
        // (which would land the user on an empty white screen).
        if finalBlocks.isEmpty && plainText.isEmpty && !hasInteractiveContent {
            throw URLIngestionError.noExtractableContent
        }

        let confidence = confidenceScore(blockCount: parsed.blocks.count, textLength: plainText.count)
        let processingState: ProcessingState = confidence >= 0.7 ? .ready : .partial
        let renderFormat: RenderFormat
        if hasInteractiveContent {
            renderFormat = .webView
        } else if finalBlocks.isEmpty {
            renderFormat = .plainText
        } else {
            renderFormat = .structuredV1
        }

        let readerDocument = ReaderDocument(
            version: 1,
            sourceURL: sourceURL.absoluteString,
            canonicalURL: canonicalURL,
            title: title,
            blocks: finalBlocks
        )

        return IngestionResult(
            title: title,
            sourceURL: sourceURL.absoluteString,
            canonicalURL: canonicalURL,
            excerpt: excerpt,
            author: author,
            publishedAt: publishedRaw.flatMap(parseDate),
            siteName: siteName,
            heroImageURL: heroImageURL,
            readingTimeMinutes: estimateReadingTime(text: plainText),
            hasRichMedia: !parsed.media.isEmpty || !allEmbeds.isEmpty,
            renderFormat: renderFormat,
            processingState: processingState,
            processingError: nil,
            document: readerDocument,
            plainText: plainText,
            media: dedupeMedia(parsed.media),
            embeds: allEmbeds
        )
    }
}

public struct MediaResolutionClient: Sendable {
    public var resolve: @Sendable ([MediaDescriptor]) async throws -> [MediaDescriptor]

    public init(resolve: @escaping @Sendable ([MediaDescriptor]) async throws -> [MediaDescriptor]) {
        self.resolve = resolve
    }

    public static let live = MediaResolutionClient { media in
        let imageDir = MediaResolutionClient.imageStorageDirectory
        try? FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

        return await withTaskGroup(of: (Int, MediaDescriptor).self, returning: [MediaDescriptor].self) { group in
            for (index, descriptor) in media.enumerated() {
                group.addTask {
                    var resolved = descriptor
                    guard descriptor.kind == .image,
                          let url = URL(string: descriptor.sourceURL),
                          let scheme = url.scheme, ["http", "https"].contains(scheme) else {
                        return (index, resolved)
                    }
                    do {
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 15
                        request.setValue(
                            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
                            forHTTPHeaderField: "User-Agent"
                        )
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard let httpResponse = response as? HTTPURLResponse,
                              (200..<300).contains(httpResponse.statusCode),
                              data.count < 10_000_000 else {
                            return (index, resolved)
                        }
                        let filename = url.lastPathComponent.isEmpty
                            ? UUID().uuidString + ".jpg"
                            : url.lastPathComponent
                        let localFile = imageDir.appendingPathComponent(filename)
                        try data.write(to: localFile)
                        resolved.localURL = localFile.path
                    } catch {
                        // Network failure — leave localURL nil, CachedImageView will fetch on demand.
                    }
                    return (index, resolved)
                }
            }

            var results: [(Int, MediaDescriptor)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Persistent directory for downloaded article images (Documents/StowerImages).
    /// Not in Caches — the system won't evict these.
    static let imageStorageDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("StowerImages", isDirectory: true)
    }()
}

public struct ReaderRenderClient: Sendable {
    public var normalized: @Sendable (ReaderDocument) -> ReaderDocument

    public init(normalized: @escaping @Sendable (ReaderDocument) -> ReaderDocument) {
        self.normalized = normalized
    }

    public static let live = ReaderRenderClient { $0 }
}

// MARK: - Dependency Keys

private enum URLIngestionClientKey: DependencyKey {
    static let liveValue = URLIngestionClient.live
    static let testValue = URLIngestionClient.failing
}

private enum ExtractionPipelineClientKey: DependencyKey {
    static let liveValue = ExtractionPipelineClient.live
    static let testValue = ExtractionPipelineClient { _, sourceURL in
        IngestionResult.sharedText(sourceURL.absoluteString)
    }
}

private enum MediaResolutionClientKey: DependencyKey {
    static let liveValue = MediaResolutionClient.live
    static let testValue = MediaResolutionClient { $0 }
}

private enum ReaderRenderClientKey: DependencyKey {
    static let liveValue = ReaderRenderClient.live
    static let testValue = ReaderRenderClient { $0 }
}

extension DependencyValues {
    public var urlIngestionClient: URLIngestionClient {
        get { self[URLIngestionClientKey.self] }
        set { self[URLIngestionClientKey.self] = newValue }
    }

    public var extractionPipelineClient: ExtractionPipelineClient {
        get { self[ExtractionPipelineClientKey.self] }
        set { self[ExtractionPipelineClientKey.self] = newValue }
    }

    public var mediaResolutionClient: MediaResolutionClient {
        get { self[MediaResolutionClientKey.self] }
        set { self[MediaResolutionClientKey.self] = newValue }
    }

    public var readerRenderClient: ReaderRenderClient {
        get { self[ReaderRenderClientKey.self] }
        set { self[ReaderRenderClientKey.self] = newValue }
    }
}

// MARK: - Interactive Content Detection

/// Returns true if the document contains interactive SVGs, canvas elements, or
/// known data-visualization libraries that require JavaScript to render correctly.
///
/// The goal is to only flag pages that meaningfully break when rendered as
/// stripped structured text (interactive charts, animated SVGs, <canvas>
/// simulations). UI frameworks like React/Vue/Svelte don't count — they're
/// used by practically every modern website and "React = interactive" would
/// route every article through the raw-HTML WebView path, which is almost
/// never what the reader wants.
func detectInteractiveContent(document: Document) -> Bool {
    // Canvas elements always require JS.
    let canvasCount = (try? document.select("canvas").array().count) ?? 0
    if canvasCount > 0 { return true }

    // SVGs that carry real interactivity: embedded <script>, SMIL animation,
    // or <foreignObject>. Child-count alone is a bad heuristic because
    // icon SVGs commonly have dozens of <path> children.
    let svgs = (try? document.select("svg").array()) ?? []
    for svg in svgs {
        if (try? svg.select("script, animate, animateTransform, animateMotion, set, foreignObject").first()) != nil {
            return true
        }
    }

    // Scripts that reference known data-visualization libraries. Restrict to
    // actual charting/viz toolkits — UI frameworks are intentionally excluded.
    let scripts = (try? document.select("script[src]").array()) ?? []
    let vizPatterns = ["d3.js", "d3.min.js", "/d3/", "chart.js", "chartjs", "highcharts", "plotly", "vega", "observablehq"]
    for script in scripts {
        let src = ((try? script.attr("src")) ?? "").lowercased()
        if vizPatterns.contains(where: src.contains) { return true }
    }

    // Inline scripts that construct charts or drive SVG animations. Match on
    // distinctive API calls instead of bare DOM primitives — `setAttribute`
    // and `appendChild` appear in practically any modern site's bundled JS.
    let inlineScripts = (try? document.select("script:not([src])").array()) ?? []
    let vizCallPatterns = ["d3.select(", "new Chart(", "Highcharts.chart(", "Plotly.newPlot(", "vega.embed(", "createElementNS(\"http://www.w3.org/2000/svg\""]
    for script in inlineScripts {
        let content = (try? script.html()) ?? ""
        if vizCallPatterns.contains(where: content.contains) { return true }
    }

    return false
}
