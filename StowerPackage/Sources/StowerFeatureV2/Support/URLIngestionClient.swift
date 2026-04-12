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

        // If the URL resolves to a PDF (via Content-Type or a body sniff),
        // route through PDFIngestionClient instead of the HTML pipeline. The
        // staged file path is handed downstream via `pdfSHA256` so
        // `processIngestionJobs` can place the file in the archive after the
        // item ID is assigned.
        if let pdfResult = try await maybeIngestAsPDF(url: url) {
            return pdfResult
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(bytes: data, encoding: .utf8) ?? ""

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
            ?? parsed.media.first { $0.kind == .image }?.sourceURL

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

            // swiftlint:disable:next prefer_let_over_var
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

// MARK: - PDF URL detection

/// Attempts to short-circuit URL ingestion through the PDF pipeline when the
/// URL resolves to `application/pdf`. Sends a lightweight HEAD first to avoid
/// downloading the body when the URL is plainly an HTML article; if HEAD is
/// unhelpful, falls back to a GET and sniffs the first few bytes for `%PDF-`.
///
/// Returns nil when the resource is not a PDF (caller continues with the HTML
/// pipeline). Returns a fully-populated `IngestionResult` when the resource
/// is a PDF, with its `sourceURL`/`canonicalURL` overridden to the original
/// URL so URL-based dedup still works. Writes the PDF bytes to a deterministic
/// staging path in the temp directory so `processIngestionJobs` can place the
/// file into `StowerArchive/{itemID}/` after the item ID is assigned.
private func maybeIngestAsPDF(url: URL) async throws -> IngestionResult? {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
        return nil
    }

    // Step 1 — HEAD check.
    var headRequest = URLRequest(url: url)
    headRequest.httpMethod = "HEAD"
    headRequest.timeoutInterval = 15
    headRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    headRequest.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
        forHTTPHeaderField: "User-Agent"
    )

    var isPDFFromHead = false
    if let (_, response) = try? await URLSession.shared.data(for: headRequest),
       let http = response as? HTTPURLResponse {
        let mime = (http.mimeType ?? "").lowercased()
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if mime == "application/pdf" || contentType.hasPrefix("application/pdf") {
            isPDFFromHead = true
        }
    }

    // Step 2 — if HEAD said yes, or the URL path ends in .pdf and HEAD was
    // unhelpful, GET the body. Otherwise return nil to let the HTML pipeline
    // handle it.
    let pathLooksLikePDF = url.path.lowercased().hasSuffix(".pdf")
    guard isPDFFromHead || pathLooksLikePDF else {
        return nil
    }

    var getRequest = URLRequest(url: url)
    getRequest.timeoutInterval = 60
    getRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    getRequest.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
        forHTTPHeaderField: "User-Agent"
    )
    let (data, response) = try await URLSession.shared.data(for: getRequest)

    // Sniff: a real PDF starts with `%PDF-`. Guards against servers that
    // lie in Content-Type or that 200-OK with an HTML error page when the
    // URL ends in `.pdf`.
    let header = data.prefix(5)
    let looksLikePDF: Bool = {
        if isPDFFromHead {
            return true
        }
        guard header.count == 5 else { return false }
        return header[header.startIndex] == 0x25    // %
            && header[header.startIndex + 1] == 0x50 // P
            && header[header.startIndex + 2] == 0x44 // D
            && header[header.startIndex + 3] == 0x46 // F
            && header[header.startIndex + 4] == 0x2D // -
    }()
    guard looksLikePDF else { return nil }

    // Also catch the case where the server reported `application/pdf`
    // via GET but HEAD wasn't definitive.
    if let http = response as? HTTPURLResponse,
       let mime = http.mimeType?.lowercased(),
       mime != "application/pdf" && !looksLikePDF {
        return nil
    }

    // Step 3 — write to temp and hand to the PDF pipeline.
    let tempDir = FileManager.default.temporaryDirectory
    let scratch = tempDir.appendingPathComponent("\(UUID().uuidString).pdf")
    try data.write(to: scratch, options: .atomic)
    defer { try? FileManager.default.removeItem(at: scratch) }

    var result = try await PDFIngestionClient.live.ingest(scratch)

    // Override source/canonical to the real URL so URL-based dedup and
    // hydrate-on-second-device both work. The pdfSHA256 stays on the result
    // so AppFeature.processIngestionJobs can locate the staged file below.
    //
    // Because pdfIngest() wrote page images keyed on the SHA-based canonical
    // URL, and createItemFromIngestion will compute the item ID from the
    // HTTP URL below, we must relocate the page images to the correct
    // archive directory. Without this, the reader would look for images
    // under the HTTP-based item ID and find an empty directory.
    if let hash = result.pdfSHA256 {
        let shaCanonical = "pdf-sha256:\(hash)"
        let shaItemID = StowerRepository.stableItemID(from: shaCanonical)
        let urlItemID = StowerRepository.stableItemID(from: url.absoluteString)
        if shaItemID != urlItemID {
            try? PDFArchiver.relocatePageImages(from: shaItemID, to: urlItemID)
        }
    }

    result.sourceURL = url.absoluteString
    result.canonicalURL = url.absoluteString
    result.document.sourceURL = url.absoluteString
    result.document.canonicalURL = url.absoluteString

    // Move the scratch file to a deterministic staging path keyed on the
    // SHA-256 so `processIngestionJobs` can find and archive it after it
    // calls createItemFromIngestion. The `defer` above is then a no-op.
    if let hash = result.pdfSHA256 {
        let staged = tempDir.appendingPathComponent("stower-pdf-stage-\(hash).pdf")
        try? FileManager.default.removeItem(at: staged)
        try? FileManager.default.moveItem(at: scratch, to: staged)
    }
    return result
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
    if canvasCount > 0 {
        return true
    }

    // SVGs that carry real interactivity: embedded <script>, SMIL animation,
    // or <foreignObject>. Child-count alone is a bad heuristic because
    // icon SVGs commonly have dozens of <path> children.
    let svgs = (try? document.select("svg").array()) ?? []
    for svg in svgs {
        // swiftlint:disable:next for_where
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
        if vizPatterns.contains(where: src.contains) {
            return true
        }
    }

    // Inline scripts that construct charts or drive SVG animations. Match on
    // distinctive API calls instead of bare DOM primitives — `setAttribute`
    // and `appendChild` appear in practically any modern site's bundled JS.
    let inlineScripts = (try? document.select("script:not([src])").array()) ?? []
    let vizCallPatterns = ["d3.select(", "new Chart(", "Highcharts.chart(", "Plotly.newPlot(", "vega.embed(", "createElementNS(\"http://www.w3.org/2000/svg\""]
    for script in inlineScripts {
        let content = (try? script.html()) ?? ""
        if vizCallPatterns.contains(where: content.contains) {
            return true
        }
    }

    return false
}
