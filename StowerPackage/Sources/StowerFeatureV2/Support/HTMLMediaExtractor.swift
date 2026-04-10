import Foundation
import SwiftSoup

func imageDescriptor(_ element: Element, captionHint: String?) throws -> MediaDescriptor? {
    let source = bestImageSource(element)
    guard let source else { return nil }
    if source.lowercased().hasPrefix("data:") { return nil }

    let width = Int((try? element.attr("width")) ?? "")
    let height = Int((try? element.attr("height")) ?? "")
    let alt = nonEmpty(try? element.attr("alt"))
    let classAndID = (((try? element.className()) ?? "") + " " + element.id()).lowercased()
    let combined = (source + " " + classAndID + " " + (alt ?? "")).lowercased()

    if isLikelyAvatarImage(combined: combined, width: width, height: height) {
        return nil
    }

    return MediaDescriptor(
        kind: .image,
        sourceURL: source,
        mimeType: guessMimeType(source),
        width: width,
        height: height,
        caption: captionHint ?? alt,
        altText: alt
    )
}

func pictureDescriptor(_ element: Element, captionHint: String? = nil) throws -> MediaDescriptor? {
    if let image = try element.select("img").first(),
       let descriptor = try imageDescriptor(image, captionHint: captionHint) {
        return descriptor
    }

    guard let sourceElement = try element.select("source").first() else { return nil }
    let source = bestSourceFromSrcSet(sourceElement) ?? nonEmpty(try? sourceElement.attr("abs:srcset"))
    guard let source else { return nil }

    return MediaDescriptor(
        kind: .image,
        sourceURL: source,
        mimeType: guessMimeType(source),
        caption: captionHint
    )
}

func videoDescriptor(_ element: Element) throws -> MediaDescriptor? {
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

func embedDescriptor(_ element: Element) throws -> EmbedDescriptor? {
    let source = nonEmpty(try? element.attr("abs:src")) ?? nonEmpty(try? element.attr("src"))
    guard let source else { return nil }
    return EmbedDescriptor(provider: providerName(source), embedURL: source)
}

func discoverOEmbeds(document: Document) throws -> [EmbedDescriptor] {
    let links = try document
        .select("link[type='application/json+oembed'], link[type='text/xml+oembed']")
        .array()

    return links.compactMap { link in
        let href = nonEmpty(try? link.attr("abs:href")) ?? nonEmpty(try? link.attr("href"))
        guard let href else { return nil }
        return EmbedDescriptor(provider: "oEmbed", embedURL: href)
    }
}

func bestImageSource(_ element: Element) -> String? {
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
        if let candidate { return candidate }
    }
    return nil
}

func bestSourceFromSrcSet(_ element: Element) -> String? {
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

func isLikelyAvatarImage(combined: String, width: Int?, height: Int?) -> Bool {
    let avatarTokens = ["avatar", "profile", "author-image", "headshot", "gravatar"]
    if avatarTokens.contains(where: combined.contains) { return true }
    if let width, let height, width <= 64, height <= 64 { return true }
    if let width, width <= 48 { return true }
    if let height, height <= 48 { return true }
    return false
}

func guessMimeType(_ urlString: String) -> String? {
    let lower = urlString.lowercased()
    if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return "image/jpeg" }
    if lower.hasSuffix(".png") { return "image/png" }
    if lower.hasSuffix(".gif") { return "image/gif" }
    if lower.hasSuffix(".webp") { return "image/webp" }
    if lower.hasSuffix(".mp4") { return "video/mp4" }
    if lower.hasSuffix(".m3u8") { return "application/x-mpegURL" }
    return nil
}

func providerName(_ urlString: String) -> String {
    guard let host = URL(string: urlString)?.host else { return "Embed" }
    let parts = host.split(separator: ".")
    if parts.count >= 2 { return parts[parts.count - 2].capitalized }
    return host.capitalized
}
