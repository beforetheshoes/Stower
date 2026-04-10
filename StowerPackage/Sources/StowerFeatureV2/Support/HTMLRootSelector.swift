import Foundation
import SwiftSoup

func chooseRoot(document: Document) throws -> Element {
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
        ".article-body",
        ".story-content",
        ".page-content",
        ".prose",
        "#content",
        "[data-content]",
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

func bestRoot(from selectors: [String], in document: Document, minLength: Int) -> Element? {
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

func candidateLooksLikeNavigation(_ element: Element) -> Bool {
    let classAndID = ((try? element.className()) ?? "") + " " + element.id()
    let lowered = classAndID.lowercased()
    return lowered.contains("nav")
        || lowered.contains("menu")
        || lowered.contains("sidebar")
        || lowered.contains("footer")
}
