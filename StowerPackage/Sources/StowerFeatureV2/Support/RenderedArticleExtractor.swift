import Foundation
import StowerData
import SwiftSoup

struct RenderedArticleExtraction: Equatable, Sendable {
    var title: String
    var canonicalURL: String?
    var author: String?
    var publishedAt: Date?
    var siteName: String?
    var heroImageURL: String?
    var readerHTML: String
    var plainText: String
    var isInteractive: Bool
    var warnings: [String]
}

struct MozillaReadabilityResult: Codable, Equatable, Sendable {
    var title: String?
    var byline: String?
    var language: String?
    var content: String?
    var textContent: String?
    var excerpt: String?
    var siteName: String?
    var publishedTime: String?

    enum CodingKeys: String, CodingKey {
        case title = "title"
        case byline = "byline"
        case content = "content"
        case textContent = "textContent"
        case excerpt = "excerpt"
        case siteName = "siteName"
        case publishedTime = "publishedTime"
        case language = "lang"
    }
}

/// Readability-style extraction over the JavaScript-rendered DOM. Candidate
/// scoring follows Readability's core signals (text length, paragraph density,
/// commas and link density), then reconciles the result with the original
/// semantic article root so source order and nesting are not flattened.
enum RenderedArticleExtractor {
    private static let removalSelector = [
        "nav", "footer", "aside[role=navigation]", "form", "button", "input", "select", "textarea",
        "[hidden]", "[aria-hidden=true]", "[inert]", "[role=navigation]", "[role=dialog]",
        ".ad", ".ads", ".advert", ".advertisement", "[class*=advert]", "[id*=advert]",
        "[class*=newsletter]", "[id*=newsletter]", "[class*=subscribe]", "[id*=subscribe]",
        "[class*=recommend]", "[id*=recommend]", "[class*=related]", "[id*=related]",
        "[class*=comment]", "[id*=comment]", "[class*=share]", "[id*=share]",
        "[class*=social]", "[id*=social]", "[class*=cookie]", "[id*=cookie]",
    ].joined(separator: ",")

    static func extract(
        renderedHTML: String,
        sourceURL: URL,
        readability: MozillaReadabilityResult? = nil
    ) throws -> RenderedArticleExtraction {
        let document = try SwiftSoup.parse(renderedHTML, sourceURL.absoluteString)
        let metadata = try extractMetadata(document: document, sourceURL: sourceURL, readability: readability)
        let isInteractive = try detectMeaningfulInteractivity(document)
        let root = try selectRoot(document, readability: readability, sourceURL: sourceURL)
        let article = root.copy() as! Element
        try sanitize(article, sourceURL: sourceURL)
        try addBlockIndices(article)

        let articleText = try article.text().trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSemanticMedia = !(try article.select("img,svg,video,audio,math,table").isEmpty())
        guard articleText.count >= 40 || hasSemanticMedia else {
            throw URLIngestionError.noExtractableContent
        }
        let firstImage = try article.select("img[src]").first()?.attr("abs:src")

        let title = metadata.title
        let header = makeHeader(
            title: title,
            deck: metadata.deck,
            author: metadata.author,
            published: metadata.publishedRaw,
            siteName: metadata.siteName
        )
        let content = try article.outerHtml()
        let readerHTML = """
            <!doctype html>
            <html lang="\(escapeAttribute(metadata.language ?? "en"))">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data: blob:; media-src https: http: data: blob:; font-src https: http: data:; style-src 'unsafe-inline'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
              <title>\(escapeHTML(title))</title>
              <style id="stower-reader-css">\(baseReaderCSS)</style>
            </head>
            <body><main id="stower-reader-document">\(header)<article id="stower-reader-article">\(content)</article></main></body>
            </html>
            """
        return RenderedArticleExtraction(
            title: title,
            canonicalURL: metadata.canonicalURL,
            author: metadata.author,
            publishedAt: metadata.publishedRaw.flatMap(parseDate),
            siteName: metadata.siteName,
            heroImageURL: metadata.heroImageURL ?? firstImage,
            readerHTML: readerHTML,
            plainText: articleText,
            isInteractive: isInteractive,
            warnings: []
        )
    }

    private struct Metadata {
        var title: String
        var deck: String?
        var canonicalURL: String?
        var author: String?
        var publishedRaw: String?
        var siteName: String?
        var heroImageURL: String?
        var language: String?
    }

    private static func extractMetadata(
        document: Document,
        sourceURL: URL,
        readability: MozillaReadabilityResult?
    ) throws -> Metadata {
        let jsonLD = try jsonLDMetadata(document)
        let articleHeading = nonEmpty(try? document.select("article h1,[itemprop~=articleBody] h1,main h1,h1").first()?.text())
        let title = nonEmpty(readability?.title)
            ?? jsonLD.title
            ?? meta(document, "meta[property=og:title]")
            ?? meta(document, "meta[name=twitter:title]")
            ?? articleHeading
            ?? nonEmpty(try? document.title())
            ?? sourceURL.host
            ?? sourceURL.absoluteString
        return Metadata(
            title: title,
            deck: nonEmpty(readability?.excerpt)
                ?? jsonLD.deck
                ?? nonEmpty(try? document.select("[class*=dek],[class*=deck],[class*=standfirst],[itemprop=description]").first()?.text())
                ?? meta(document, "meta[property=og:description]"),
            canonicalURL: nonEmpty(try? document.select("link[rel=canonical]").first()?.attr("abs:href"))
                ?? meta(document, "meta[property=og:url]"),
            author: nonEmpty(readability?.byline)
                ?? jsonLD.author
                ?? meta(document, "meta[name=author]")
                ?? meta(document, "meta[property=article:author]")
                ?? nonEmpty(try? document.select("[rel=author],[itemprop=author],[class*=byline]").first()?.text()),
            publishedRaw: nonEmpty(readability?.publishedTime)
                ?? jsonLD.published
                ?? meta(document, "meta[property=article:published_time]")
                ?? meta(document, "meta[name=date]")
                ?? nonEmpty(try? document.select("time[datetime]").first()?.attr("datetime")),
            siteName: nonEmpty(readability?.siteName)
                ?? jsonLD.siteName
                ?? meta(document, "meta[property=og:site_name]")
                ?? sourceURL.host,
            heroImageURL: jsonLD.image
                ?? metaAbsolute(document, "meta[property=og:image]", sourceURL: sourceURL)
                ?? metaAbsolute(document, "meta[name=twitter:image]", sourceURL: sourceURL),
            language: nonEmpty(readability?.language)
                ?? nonEmpty(try? document.select("html[lang]").first()?.attr("lang"))
        )
    }

    private struct JSONLDMetadata {
        var title: String?
        var deck: String?
        var author: String?
        var published: String?
        var siteName: String?
        var image: String?
    }

    private static func jsonLDMetadata(_ document: Document) throws -> JSONLDMetadata {
        for script in try document.select("script[type=application/ld+json]") {
            guard let data = try script.html().data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            let candidates: [[String: Any]]
            if let object = json as? [String: Any] {
                candidates = (object["@graph"] as? [[String: Any]] ?? []) + [object]
            } else if let array = json as? [[String: Any]] {
                candidates = array
            } else { continue }
            for object in candidates where isArticleType(object["@type"]) {
                let author: String?
                if let value = object["author"] as? String {
                    author = value
                } else if let value = object["author"] as? [String: Any] {
                    author = value["name"] as? String
                } else if let values = object["author"] as? [[String: Any]] {
                    author = values.compactMap { $0["name"] as? String }.joined(separator: ", ")
                } else {
                    author = nil
                }
                let image: String?
                if let value = object["image"] as? String {
                    image = value
                } else if let value = object["image"] as? [String: Any] {
                    image = value["url"] as? String
                } else {
                    image = (object["image"] as? [String])?.first
                }
                return JSONLDMetadata(
                    title: nonEmpty(object["headline"] as? String) ?? nonEmpty(object["name"] as? String),
                    deck: nonEmpty(object["description"] as? String),
                    author: nonEmpty(author),
                    published: nonEmpty(object["datePublished"] as? String),
                    siteName: (object["publisher"] as? [String: Any])?["name"] as? String,
                    image: image
                )
            }
        }
        return JSONLDMetadata()
    }

    private static func isArticleType(_ value: Any?) -> Bool {
        let types = (value as? [String]) ?? (value as? String).map { [$0] } ?? []
        return types.contains { $0.localizedCaseInsensitiveContains("article") || $0 == "NewsArticle" }
    }

    private static func selectRoot(
        _ document: Document,
        readability: MozillaReadabilityResult?,
        sourceURL: URL
    ) throws -> Element {
        let semantic = try document.select("article,[itemprop~=articleBody]").array()
        let fallback = try document.select("main,[role=main],body").array()
        let readableNeedle = readability?.textContent
            .map(normalizedText)
            .map { String($0.prefix(180)) }
        if let readableNeedle, readableNeedle.count >= 40,
           let reconciled = semantic.max(by: {
               semanticOverlap($0, readableNeedle) < semanticOverlap($1, readableNeedle)
           }),
           semanticOverlap(reconciled, readableNeedle) >= 0.7 {
            return reconciled
        }
        if let content = readability?.content,
           let readabilityDocument = try? SwiftSoup.parseBodyFragment(content, sourceURL.absoluteString),
           let readabilityBody = readabilityDocument.body(),
           ((try? readabilityBody.text().count) ?? 0) >= 40 {
            return readabilityBody
        }
        let candidates = semantic.isEmpty ? fallback : semantic
        return candidates.max { ((try? score($0)) ?? -.infinity) < ((try? score($1)) ?? -.infinity) }
            ?? document.body()
            ?? document
    }

    private static func semanticOverlap(_ element: Element, _ needle: String) -> Double {
        let haystack = normalizedText((try? element.text()) ?? "")
        if haystack.contains(needle) {
            return 1
        }
        let words = Set<String>(needle.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count > 3 })
        guard !words.isEmpty else { return 0 }
        let haystackWords = Set<String>(haystack.split(whereSeparator: \.isWhitespace).map(String.init))
        return Double(words.intersection(haystackWords).count) / Double(words.count)
    }

    private static func normalizedText(_ value: String) -> String {
        value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func score(_ element: Element) throws -> Double {
        let text = try element.text()
        guard text.count > 0 else { return -.infinity }
        let paragraphCount = try element.select("p").count
        let commaCount = text.filter { $0 == "," }.count
        let linkText = try element.select("a").array().reduce(0) { $0 + ((try? $1.text().count) ?? 0) }
        let linkDensity = Double(linkText) / Double(max(text.count, 1))
        return (Double(text.count) + Double(paragraphCount * 120 + commaCount * 8)) * (1 - min(linkDensity, 0.95))
    }

    private static func sanitize(_ root: Element, sourceURL: URL) throws {
        try root.select(removalSelector).remove()
        try root.select("script,style,link,meta,base,object,embed,canvas,noscript,template").remove()
        try root.select("svg script,svg foreignObject,svg animate,svg set").remove()

        for iframe in try root.select("iframe[src]").array() {
            let url = try iframe.attr("abs:src")
            let launcher = Element(try Tag.valueOf("p"), sourceURL.absoluteString)
            try launcher.addClass("stower-embed-launcher")
            if isSafeURL(url, allowDataImage: false) {
                let link = Element(try Tag.valueOf("a"), sourceURL.absoluteString)
                try link.attr("href", url)
                try link.text("Open embedded content")
                try launcher.appendChild(link)
            }
            try iframe.replaceWith(launcher)
        }

        for element in try root.getAllElements().array() {
            for attribute in element.getAttributes()?.asList() ?? [] {
                let name = attribute.getKey().lowercased()
                if name.hasPrefix("on") || name == "style" || name == "srcdoc" || name == "nonce"
                    || name.hasPrefix("data-") && name != "data-block-index" {
                    try element.removeAttr(attribute.getKey())
                    continue
                }
                if ["href", "src", "poster", "cite", "xlink:href"].contains(name) {
                    let absolute = try element.attr("abs:\(attribute.getKey())")
                    let value = absolute.isEmpty ? attribute.getValue() : absolute
                    if isSafeURL(value, allowDataImage: name == "src") {
                        try element.attr(attribute.getKey(), value)
                    } else {
                        try element.removeAttr(attribute.getKey())
                    }
                }
            }
            if element.tagName() == "a" {
                try element.attr("rel", "noopener noreferrer")
                try element.attr("target", "_blank")
            }
        }
        try root.select("img[width=1],img[height=1]").remove()
    }

    private static func addBlockIndices(_ root: Element) throws {
        let blocks = try root.select("h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,figure,table,dl,details,math,svg,video,audio,.stower-embed-launcher")
        for (index, element) in blocks.array().enumerated() {
            try element.attr("data-block-index", String(index))
        }
    }

    private static func detectMeaningfulInteractivity(_ document: Document) throws -> Bool {
        if !(try document.select("canvas,model-viewer,iframe[src],video[src],audio[src]").isEmpty()) {
            return true
        }
        if !(try document.select("svg [onclick],svg animate,svg animateTransform,svg[role=application]").isEmpty()) {
            return true
        }
        let scripts = try document.select("script").array()
        return scripts.contains { script in
            let source = ((try? script.attr("src")) ?? "") + script.data()
            return ["d3.", "three.", "chart.js", "webgl", "addEventListener(\"pointer", "addEventListener('pointer"]
                .contains { source.localizedCaseInsensitiveContains($0) }
        }
    }

    private static func makeHeader(title: String, deck: String?, author: String?, published: String?, siteName: String?) -> String {
        let site = siteName.map { "<p class=\"stower-site\">\(escapeHTML($0))</p>" } ?? ""
        let deckHTML = deck.map { "<p class=\"stower-deck\">\(escapeHTML($0))</p>" } ?? ""
        let byline = author.map { "<span class=\"stower-byline\">\(escapeHTML($0))</span>" } ?? ""
        let date = published.map { "<time>\(escapeHTML($0))</time>" } ?? ""
        return "<header class=\"stower-header\">\(site)<h1 data-block-index=\"0\">\(escapeHTML(title))</h1>\(deckHTML)<p class=\"stower-meta\">\(byline) \(date)</p></header>"
    }

    private static func meta(_ document: Document, _ selector: String) -> String? {
        nonEmpty(try? document.select(selector).first()?.attr("content"))
    }

    private static func metaAbsolute(_ document: Document, _ selector: String, sourceURL: URL) -> String? {
        guard let raw = meta(document, selector) else { return nil }
        return URL(string: raw, relativeTo: sourceURL)?.absoluteURL.absoluteString
    }

    private static func isSafeURL(_ value: String, allowDataImage: Bool) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        if ["http", "https", "mailto"].contains(scheme) {
            return true
        }
        return allowDataImage && scheme == "data" && value.lowercased().hasPrefix("data:image/")
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeAttribute(_ value: String) -> String { escapeHTML(value) }

    private static let baseReaderCSS = """
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        body { margin: 0; background: transparent; color: inherit; }
        #stower-reader-document { width: min(100% - 32px, 820px); margin: 0 auto; padding: 48px 0 96px; }
        img, picture, video, svg { max-width: 100%; height: auto; }
        figure { margin-inline: 0; } figcaption { opacity: .72; }
        table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; }
        th, td { padding: .45em .6em; border: 1px solid currentColor; }
        pre { overflow-x: auto; white-space: pre; } code, pre { font-family: ui-monospace, monospace; }
        blockquote { margin-inline: 0; padding-inline-start: 1em; border-inline-start: 3px solid currentColor; }
        .stower-header { margin-bottom: 2.5em; } .stower-site { opacity: .65; }
        .stower-deck { font-size: 1.15em; opacity: .8; } .stower-meta { opacity: .7; }
        .stower-embed-launcher { padding: 1em; border: 1px solid currentColor; border-radius: .5em; }
        """
}
