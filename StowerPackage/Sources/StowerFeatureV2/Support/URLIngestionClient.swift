import Dependencies
import Foundation
import SwiftSoup

public struct URLIngestionClient: Sendable {
    public var ingest: @Sendable (URL) async throws -> IngestionResult

    public init(ingest: @escaping @Sendable (URL) async throws -> IngestionResult) {
        self.ingest = ingest
    }

    public static let failing = URLIngestionClient { _ in
        throw URLError(.badURL)
    }

    public static let live = URLIngestionClient { url in
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

        let confidence = confidenceScore(blockCount: parsed.blocks.count, textLength: plainText.count)
        let processingState: ProcessingState = confidence >= 0.7 ? .ready : .partial
        let renderFormat: RenderFormat = finalBlocks.isEmpty ? .plainText : .structuredV1

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

    public static let live = MediaResolutionClient { $0 }
}

public struct ReaderRenderClient: Sendable {
    public var normalized: @Sendable (ReaderDocument) -> ReaderDocument

    public init(normalized: @escaping @Sendable (ReaderDocument) -> ReaderDocument) {
        self.normalized = normalized
    }

    public static let live = ReaderRenderClient { $0 }
}

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

private struct ParsedBlocks {
    var blocks: [ReaderBlock]
    var media: [MediaDescriptor]
    var embeds: [EmbedDescriptor]
}

private func extractTitle(document: Document, sourceURL: URL) throws -> String {
    let candidates: [String?] = [
        nonEmpty(try? document.select("meta[property=og:title]").first()?.attr("content")),
        nonEmpty(try? document.select("meta[name=twitter:title]").first()?.attr("content")),
        nonEmpty(try? document.title()),
        sourceURL.host,
        sourceURL.absoluteString,
    ]

    for candidate in candidates {
        if let candidate {
            return candidate
        }
    }
    return sourceURL.absoluteString
}

private func chooseRoot(document: Document) throws -> Element {
    let preferredSelectors = [
        "article",
        "main article",
        "[role=main] article",
        "[itemprop=articleBody]",
    ]

    let fallbackSelectors = [
        "main",
        "[role=main]",
        ".post-content",
        ".entry-content",
        ".article-content",
        ".content",
        "body",
    ]

    if let preferred = bestRoot(from: preferredSelectors, in: document, minLength: 300) {
        return preferred
    }

    if let fallback = bestRoot(from: fallbackSelectors, in: document, minLength: 120) {
        return fallback
    }

    if let body = document.body() {
        return body
    }

    throw URLError(.cannotParseResponse)
}

private func bestRoot(from selectors: [String], in document: Document, minLength: Int) -> Element? {
    var best: Element?
    var bestScore = Int.min

    for selector in selectors {
        let candidates = (try? document.select(selector).array()) ?? []
        for candidate in candidates {
            let textLength = cleanText((try? candidate.text()) ?? "").count
            guard textLength >= minLength else { continue }

            let pCount = (try? candidate.select("p").array().count) ?? 0
            let hCount = (try? candidate.select("h1,h2,h3").array().count) ?? 0
            let linkTextLength = cleanText((try? candidate.select("a").text()) ?? "").count
            let linkDensity = textLength > 0 ? Double(linkTextLength) / Double(textLength) : 1.0
            let navPenalty = candidateLooksLikeNavigation(candidate) ? 5000 : 0

            let score = textLength + (pCount * 140) + (hCount * 90) - Int(linkDensity * 900) - navPenalty
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
    }

    return best
}

private func candidateLooksLikeNavigation(_ element: Element) -> Bool {
    let classAndID = ((try? element.className()) ?? "") + " " + element.id()
    let lowered = classAndID.lowercased()
    return lowered.contains("nav")
        || lowered.contains("menu")
        || lowered.contains("sidebar")
        || lowered.contains("footer")
}

private func parseBlocks(root: Element, baseURL: URL) throws -> ParsedBlocks {
    let cleanedDoc = try SwiftSoup.parseBodyFragment(try root.outerHtml(), baseURL.absoluteString)
    guard let body = cleanedDoc.body() else {
        return ParsedBlocks(blocks: [], media: [], embeds: [])
    }

    try body.select(
        "script, style, svg, canvas, template, nav, footer, header, aside, form, button, [aria-hidden=true], [hidden], .sr-only, .visually-hidden, .screen-reader-text, .sidebar, .related, .share, .comments"
    ).remove()

    var blocks: [ReaderBlock] = []
    var media: [MediaDescriptor] = []
    var embeds: [EmbedDescriptor] = []

    for childNode in body.getChildNodes() {
        guard let child = childNode as? Element else { continue }
        let parsed = try parseBlock(child)
        blocks.append(contentsOf: parsed.blocks)
        media.append(contentsOf: parsed.media)
        embeds.append(contentsOf: parsed.embeds)
    }

    if blocks.isEmpty {
        let descendantFallback = try parseFallbackDescendants(body)
        blocks = descendantFallback.blocks
        media.append(contentsOf: descendantFallback.media)
        embeds.append(contentsOf: descendantFallback.embeds)
    }

    if blocks.isEmpty {
        let fallback = cleanText((try? body.text()) ?? "")
        if !fallback.isEmpty {
            blocks = splitLongParagraph(fallback).map { .paragraph([.text($0)]) }
        }
    }

    return ParsedBlocks(blocks: blocks, media: media, embeds: embeds)
}

private func parseBlock(_ element: Element) throws -> ParsedBlocks {
    let tag = element.tagName().lowercased()

    switch tag {
    case "h1", "h2", "h3", "h4", "h5", "h6":
        let level = Int(String(tag.dropFirst())) ?? 1
        let inlines = try parseInlines(element)
        return ParsedBlocks(blocks: inlines.isEmpty ? [] : [.heading(level: level, inlines: inlines)], media: [], embeds: [])

    case "p":
        let inlines = try parseInlines(element)
        var blocks: [ReaderBlock] = inlines.isEmpty ? [] : [.paragraph(inlines)]
        var media: [MediaDescriptor] = []
        var embeds: [EmbedDescriptor] = []

        // Keep rich media nested in paragraph wrappers (common on Substack).
        let mediaNodes = try element.select("img,picture,video,iframe,figure").array()
        for mediaNode in mediaNodes {
            let parsed = try parseBlock(mediaNode)
            blocks.append(contentsOf: parsed.blocks)
            media.append(contentsOf: parsed.media)
            embeds.append(contentsOf: parsed.embeds)
        }

        return ParsedBlocks(blocks: dedupeBlocks(blocks), media: dedupeMedia(media), embeds: dedupeEmbeds(embeds))

    case "ul", "ol":
        let listItems = try element.select("> li").array().map { try parseInlines($0) }.filter { !$0.isEmpty }
        return ParsedBlocks(blocks: listItems.isEmpty ? [] : [.list(ordered: tag == "ol", items: listItems)], media: [], embeds: [])

    case "blockquote":
        let inlines = try parseInlines(element)
        return ParsedBlocks(blocks: inlines.isEmpty ? [] : [.blockquote(inlines)], media: [], embeds: [])

    case "pre":
        let language = nonEmpty(try? element.select("code").first()?.attr("class"))
        let code = cleanText((try? element.text()) ?? "")
        if code.isEmpty {
            return ParsedBlocks(blocks: [], media: [], embeds: [])
        }
        return ParsedBlocks(blocks: [.code(language: language, code: code)], media: [], embeds: [])

    case "img":
        guard let image = try imageDescriptor(element, captionHint: nil) else {
            return ParsedBlocks(blocks: [], media: [], embeds: [])
        }
        return ParsedBlocks(blocks: [.figure(media: image)], media: [image], embeds: [])

    case "picture":
        guard let image = try pictureDescriptor(element) else {
            return ParsedBlocks(blocks: [], media: [], embeds: [])
        }
        return ParsedBlocks(blocks: [.figure(media: image)], media: [image], embeds: [])

    case "noscript":
        let raw = cleanText((try? element.html()) ?? "")
        guard !raw.isEmpty else { return ParsedBlocks(blocks: [], media: [], embeds: []) }
        let fragment = try SwiftSoup.parseBodyFragment(raw)
        guard let fragmentBody = fragment.body() else {
            return ParsedBlocks(blocks: [], media: [], embeds: [])
        }
        var combined = ParsedBlocks(blocks: [], media: [], embeds: [])
        for node in fragmentBody.getChildNodes() {
            guard let child = node as? Element else { continue }
            let parsed = try parseBlock(child)
            combined.blocks.append(contentsOf: parsed.blocks)
            combined.media.append(contentsOf: parsed.media)
            combined.embeds.append(contentsOf: parsed.embeds)
        }
        return combined

    case "video":
        guard let video = try videoDescriptor(element) else {
            return ParsedBlocks(blocks: [], media: [], embeds: [])
        }
        return ParsedBlocks(blocks: [.video(media: video)], media: [video], embeds: [])

    case "iframe":
        guard let embed = try embedDescriptor(element) else {
            return ParsedBlocks(blocks: [], media: [], embeds: [])
        }
        return ParsedBlocks(blocks: [.embed(embed)], media: [], embeds: [embed])

    case "hr":
        return ParsedBlocks(blocks: [.horizontalRule], media: [], embeds: [])

    case "figure":
        let caption = nonEmpty(try? element.select("figcaption").first()?.text())
        if let imageElement = try element.select("img").first(),
           let image = try imageDescriptor(imageElement, captionHint: caption) {
            return ParsedBlocks(blocks: [.figure(media: image)], media: [image], embeds: [])
        }
        if let pictureElement = try element.select("picture").first(),
           let image = try pictureDescriptor(pictureElement, captionHint: caption) {
            return ParsedBlocks(blocks: [.figure(media: image)], media: [image], embeds: [])
        }
        return ParsedBlocks(blocks: [], media: [], embeds: [])

    default:
        var combined = ParsedBlocks(blocks: [], media: [], embeds: [])
        for node in element.getChildNodes() {
            guard let child = node as? Element else { continue }
            let parsed = try parseBlock(child)
            combined.blocks.append(contentsOf: parsed.blocks)
            combined.media.append(contentsOf: parsed.media)
            combined.embeds.append(contentsOf: parsed.embeds)
        }
        if combined.blocks.isEmpty {
            let ownText = cleanText(element.ownText())
            if !ownText.isEmpty {
                combined.blocks = [.paragraph([.text(ownText)])]
            }
        }
        return combined
    }
}

private func parseInlines(_ element: Element) throws -> [ReaderInline] {
    var inlines: [ReaderInline] = []

    for node in element.getChildNodes() {
        if let textNode = node as? TextNode {
            let text = cleanText(textNode.text())
            if !text.isEmpty {
                inlines.append(.text(text))
            }
            continue
        }

        guard let child = node as? Element else { continue }
        let tag = child.tagName().lowercased()

        switch tag {
        case "a":
            let label = cleanText((try? child.text()) ?? "")
            let href = nonEmpty(try? child.attr("abs:href")) ?? nonEmpty(try? child.attr("href")) ?? ""
            if !label.isEmpty, !href.isEmpty {
                inlines.append(.link(label: label, url: href))
            } else if !label.isEmpty {
                inlines.append(.text(label))
            }

        case "em", "i":
            let value = cleanText((try? child.text()) ?? "")
            if !value.isEmpty { inlines.append(.emphasis(value)) }

        case "strong", "b":
            let value = cleanText((try? child.text()) ?? "")
            if !value.isEmpty { inlines.append(.strong(value)) }

        case "code":
            let value = cleanText((try? child.text()) ?? "")
            if !value.isEmpty { inlines.append(.code(value)) }

        case "del", "s":
            let value = cleanText((try? child.text()) ?? "")
            if !value.isEmpty { inlines.append(.strikethrough(value)) }

        case "br":
            inlines.append(.text("\n"))

        default:
            inlines.append(contentsOf: try parseInlines(child))
        }
    }

    return mergeTextInlines(inlines)
}

private func mergeTextInlines(_ inlines: [ReaderInline]) -> [ReaderInline] {
    var merged: [ReaderInline] = []
    for inline in inlines {
        if case .text(let current) = inline,
           case .text(let previous)? = merged.last {
            merged.removeLast()
            merged.append(.text(previous + " " + current))
        } else {
            merged.append(inline)
        }
    }
    return merged
}

private func imageDescriptor(_ element: Element, captionHint: String?) throws -> MediaDescriptor? {
    let source = bestImageSource(element)
    guard let source else { return nil }
    if source.lowercased().hasPrefix("data:") {
        return nil
    }

    let width = Int((try? element.attr("width")) ?? "")
    let height = Int((try? element.attr("height")) ?? "")
    let alt = nonEmpty(try? element.attr("alt"))
    let classAndID = (((try? element.className()) ?? "") + " " + element.id()).lowercased()
    let combined = (source + " " + classAndID + " " + (alt ?? "")).lowercased()

    if isLikelyAvatarImage(combined: combined, width: width, height: height) {
        return nil
    }

    let caption = captionHint ?? alt

    return MediaDescriptor(
        kind: .image,
        sourceURL: source,
        mimeType: guessMimeType(source),
        width: width,
        height: height,
        caption: caption,
        altText: alt
    )
}

private func pictureDescriptor(_ element: Element, captionHint: String? = nil) throws -> MediaDescriptor? {
    if let image = try element.select("img").first(),
       let descriptor = try imageDescriptor(image, captionHint: captionHint) {
        return descriptor
    }

    guard let sourceElement = try element.select("source").first() else {
        return nil
    }
    let source = bestSourceFromSrcSet(sourceElement) ?? nonEmpty(try? sourceElement.attr("abs:srcset"))
    guard let source else { return nil }

    return MediaDescriptor(
        kind: .image,
        sourceURL: source,
        mimeType: guessMimeType(source),
        caption: captionHint
    )
}

private func videoDescriptor(_ element: Element) throws -> MediaDescriptor? {
    let source = nonEmpty(try? element.attr("abs:src"))
        ?? nonEmpty(try? element.attr("src"))
        ?? nonEmpty(try? element.select("source").first()?.attr("abs:src"))
    guard let source else { return nil }

    let poster = nonEmpty(try? element.attr("abs:poster"))
    let width = Int((try? element.attr("width")) ?? "")
    let height = Int((try? element.attr("height")) ?? "")

    return MediaDescriptor(
        kind: .video,
        sourceURL: source,
        mimeType: guessMimeType(source),
        width: width,
        height: height,
        posterURL: poster
    )
}

private func embedDescriptor(_ element: Element) throws -> EmbedDescriptor? {
    let source = nonEmpty(try? element.attr("abs:src")) ?? nonEmpty(try? element.attr("src"))
    guard let source else { return nil }
    return EmbedDescriptor(provider: providerName(source), embedURL: source)
}

private func discoverOEmbeds(document: Document) throws -> [EmbedDescriptor] {
    let links = try document
        .select("link[type='application/json+oembed'], link[type='text/xml+oembed']")
        .array()

    return links.compactMap { link in
        let href = nonEmpty(try? link.attr("abs:href")) ?? nonEmpty(try? link.attr("href"))
        guard let href else { return nil }
        return EmbedDescriptor(provider: "oEmbed", embedURL: href)
    }
}

private func bestImageSource(_ element: Element) -> String? {
    let candidates: [String?] = [
        nonEmpty(try? element.attr("abs:src")),
        nonEmpty(try? element.attr("src")),
        nonEmpty(try? element.attr("abs:data-src")),
        nonEmpty(try? element.attr("data-src")),
        nonEmpty(try? element.attr("abs:data-original")),
        nonEmpty(try? element.attr("data-original")),
        nonEmpty(try? element.attr("abs:data-lazy-src")),
        nonEmpty(try? element.attr("data-lazy-src")),
        bestSourceFromSrcSet(element),
    ]

    for candidate in candidates {
        if let candidate {
            return candidate
        }
    }
    return nil
}

private func bestSourceFromSrcSet(_ element: Element) -> String? {
    let srcSet = nonEmpty(try? element.attr("abs:srcset"))
        ?? nonEmpty(try? element.attr("srcset"))
        ?? nonEmpty(try? element.attr("data-srcset"))
        ?? nonEmpty(try? element.attr("abs:data-srcset"))

    guard let srcSet else { return nil }

    let entries = srcSet.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    var bestURL: String?
    var bestScore = -1

    for entry in entries {
        let parts = entry.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = parts.first else { continue }
        let url = String(first)
        var score = 1
        if parts.count > 1 {
            let descriptor = String(parts[1]).lowercased()
            if descriptor.hasSuffix("w") {
                score = Int(descriptor.dropLast()) ?? 1
            } else if descriptor.hasSuffix("x") {
                score = (Int(descriptor.dropLast()) ?? 1) * 1000
            }
        }
        if score > bestScore {
            bestScore = score
            bestURL = url
        }
    }

    return bestURL
}

private func isLikelyAvatarImage(combined: String, width: Int?, height: Int?) -> Bool {
    let avatarTokens = ["avatar", "profile", "author-image", "headshot", "gravatar"]
    if avatarTokens.contains(where: combined.contains) {
        return true
    }

    if let width, let height, width <= 64, height <= 64 {
        return true
    }
    if let width, width <= 48 {
        return true
    }
    if let height, height <= 48 {
        return true
    }

    return false
}

private func plainTextFromBlocks(_ blocks: [ReaderBlock]) -> String {
    var parts: [String] = []
    for block in blocks {
        switch block {
        case .paragraph(let inlines):
            parts.append(inlineText(inlines))
        case .heading(_, let inlines):
            parts.append(inlineText(inlines))
        case .list(_, let items):
            parts.append(items.map(inlineText).joined(separator: "\n"))
        case .blockquote(let inlines):
            parts.append(inlineText(inlines))
        case .code(_, let code):
            parts.append(code)
        case .figure(let media):
            if let caption = media.caption { parts.append(caption) }
        case .video(let media):
            if let caption = media.caption { parts.append(caption) }
        case .embed:
            continue
        case .table(let markdown):
            parts.append(markdown)
        case .horizontalRule:
            continue
        case .callout(let title, let inlines):
            if let title { parts.append(title) }
            parts.append(inlineText(inlines))
        }
    }

    return parts
        .joined(separator: "\n\n")
        .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func inlineText(_ inlines: [ReaderInline]) -> String {
    inlines.map {
        switch $0 {
        case .text(let value): return value
        case .link(let label, _): return label
        case .emphasis(let value): return value
        case .strong(let value): return value
        case .code(let value): return value
        case .strikethrough(let value): return value
        }
    }
    .joined(separator: " ")
    .replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func confidenceScore(blockCount: Int, textLength: Int) -> Double {
    let lengthScore = min(Double(textLength) / 2500.0, 1.0)
    let blockScore = min(Double(blockCount) / 30.0, 1.0)
    return (lengthScore * 0.6) + (blockScore * 0.4)
}

private func parseFallbackDescendants(_ body: Element) throws -> ParsedBlocks {
    var blocks: [ReaderBlock] = []
    var media: [MediaDescriptor] = []
    var embeds: [EmbedDescriptor] = []

    let candidates = try body.select("h1,h2,h3,h4,h5,h6,p,blockquote,pre,ul,ol,img,video,iframe,figure").array()
    for element in candidates {
        let parsed = try parseBlock(element)
        blocks.append(contentsOf: parsed.blocks)
        media.append(contentsOf: parsed.media)
        embeds.append(contentsOf: parsed.embeds)
    }

    return ParsedBlocks(
        blocks: dedupeBlocks(blocks),
        media: dedupeMedia(media),
        embeds: dedupeEmbeds(embeds)
    )
}

private func splitLongParagraph(_ text: String) -> [String] {
    let cleaned = cleanText(text)
    guard cleaned.count > 420 else { return [cleaned] }

    let pieces = cleaned
        .replacingOccurrences(of: "(?<=[.!?])\\s+(?=[A-Z0-9])", with: "\n", options: .regularExpression)
        .split(separator: "\n")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    return pieces.isEmpty ? [cleaned] : pieces
}

private func dedupeBlocks(_ input: [ReaderBlock]) -> [ReaderBlock] {
    var seen: Set<String> = []
    var output: [ReaderBlock] = []

    for block in input {
        let fingerprint = String(describing: block)
        if seen.contains(fingerprint) { continue }
        seen.insert(fingerprint)
        output.append(block)
    }

    return output
}

private func estimateReadingTime(text: String) -> Int {
    let words = text.split(separator: " ").count
    return max(1, Int(ceil(Double(words) / 225.0)))
}

private func parseDate(_ raw: String) -> Date? {
    let iso = ISO8601DateFormatter()
    if let value = iso.date(from: raw) {
        return value
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: raw)
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let cleaned = cleanText(value)
    return cleaned.isEmpty ? nil : cleaned
}

private func cleanText(_ text: String) -> String {
    let unescaped = (try? Entities.unescape(text)) ?? text
    return unescaped
        .replacingOccurrences(of: "[\\t\\n\\r ]+", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\u{00A0}", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func sanitizeBlocks(_ input: [ReaderBlock]) -> [ReaderBlock] {
    var output: [ReaderBlock] = []

    for block in input {
        if shouldAlwaysKeepBlock(block) {
            output.append(block)
            continue
        }

        let text = blockText(block).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if case .horizontalRule = block {
                output.append(block)
            }
            continue
        }
        if isLikelyBoilerplateText(text) {
            continue
        }
        output.append(block)
    }

    return dedupeBlocks(output)
}

private func shouldAlwaysKeepBlock(_ block: ReaderBlock) -> Bool {
    switch block {
    case .figure, .video, .embed, .table:
        return true
    default:
        return false
    }
}

private func blockText(_ block: ReaderBlock) -> String {
    switch block {
    case .paragraph(let inlines):
        return inlineText(inlines)
    case .heading(_, let inlines):
        return inlineText(inlines)
    case .list(_, let items):
        return items.map(inlineText).joined(separator: " ")
    case .blockquote(let inlines):
        return inlineText(inlines)
    case .code(_, let code):
        return code
    case .figure(let media):
        return media.caption ?? media.altText ?? ""
    case .video(let media):
        return media.caption ?? ""
    case .embed(let embed):
        return embed.provider + " " + embed.embedURL
    case .table(let markdown):
        return markdown
    case .horizontalRule:
        return ""
    case .callout(let title, let inlines):
        return (title ?? "") + " " + inlineText(inlines)
    }
}

private func isLikelyBoilerplateText(_ rawText: String) -> Bool {
    let text = cleanText(rawText)
    guard !text.isEmpty else { return true }

    let lowered = text.lowercased()
    let bannedPhrases = [
        "all items",
        "updated ",
        "on taking breaks",
        "attention and its enemies",
        "the slow web",
    ]
    if bannedPhrases.contains(where: lowered.contains) {
        return true
    }

    let words = text.split(separator: " ")
    let tokenCount = words.count
    let punctuationCount = text.filter { ".,;:!?".contains($0) }.count
    let digitCount = text.filter(\.isNumber).count
    let letterCount = text.filter(\.isLetter).count
    let camelTransitions = zip(text, text.dropFirst()).reduce(into: 0) { total, pair in
        if pair.0.isLowercase && pair.1.isUppercase {
            total += 1
        }
    }

    if tokenCount >= 14 && punctuationCount == 0 {
        return true
    }

    if letterCount > 0, Double(digitCount) / Double(letterCount) > 0.22, tokenCount >= 10 {
        return true
    }

    if camelTransitions >= 6 && punctuationCount <= 1 {
        return true
    }

    if text.range(of: "[A-Za-z]{2,}\\d{1,4}[A-Za-z]{2,}", options: .regularExpression) != nil {
        return true
    }

    return false
}

private func dedupeMedia(_ input: [MediaDescriptor]) -> [MediaDescriptor] {
    var seen: Set<String> = []
    return input.filter {
        if seen.contains($0.sourceURL) { return false }
        seen.insert($0.sourceURL)
        return true
    }
}

private func dedupeEmbeds(_ input: [EmbedDescriptor]) -> [EmbedDescriptor] {
    var seen: Set<String> = []
    return input.filter {
        if seen.contains($0.embedURL) { return false }
        seen.insert($0.embedURL)
        return true
    }
}

private func providerName(_ urlString: String) -> String {
    guard let host = URL(string: urlString)?.host else { return "Embed" }
    let parts = host.split(separator: ".")
    if parts.count >= 2 {
        return parts[parts.count - 2].capitalized
    }
    return host.capitalized
}

private func guessMimeType(_ urlString: String) -> String? {
    let lower = urlString.lowercased()
    if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return "image/jpeg" }
    if lower.hasSuffix(".png") { return "image/png" }
    if lower.hasSuffix(".gif") { return "image/gif" }
    if lower.hasSuffix(".webp") { return "image/webp" }
    if lower.hasSuffix(".mp4") { return "video/mp4" }
    if lower.hasSuffix(".m3u8") { return "application/x-mpegURL" }
    return nil
}
