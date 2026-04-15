import Foundation

func sanitizeBlocks(_ input: [ReaderBlock]) -> [ReaderBlock] {
    var output = [ReaderBlock]()

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
        if isLikelyBoilerplateText(text) { continue }
        output.append(block)
    }

    return dedupeBlocks(output)
}

func shouldAlwaysKeepBlock(_ block: ReaderBlock) -> Bool {
    switch block {
    case .figure, .video, .embed, .table:
        return true
    default:
        return false
    }
}

func blockText(_ block: ReaderBlock) -> String {
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
    case let .callout(title, inlines):
        return (title ?? "") + " " + inlineText(inlines)
    }
}

func isLikelyBoilerplateText(_ rawText: String) -> Bool {
    let text = cleanText(rawText)
    guard !text.isEmpty else { return true }

    let words = text.split(separator: " ")
    let tokenCount = words.count
    let punctuationCount = text.filter { ".,;:!?".contains($0) }.count
    let digitCount = text.filter(\.isNumber).count
    let letterCount = text.filter(\.isLetter).count
    let camelTransitions = zip(text, text.dropFirst()).reduce(into: 0) { total, pair in
        if pair.0.isLowercase && pair.1.isUppercase { total += 1 }
    }

    // Long runs with zero punctuation are likely navigation menus or tag lists.
    // Raised threshold from 14 to 22 to avoid false positives on real article text.
    if tokenCount >= 22 && punctuationCount == 0 {
        return true
    }
    // High digit-to-letter ratio suggests hashes, IDs, or machine-generated text.
    if letterCount > 0, Double(digitCount) / Double(letterCount) > 0.22, tokenCount >= 10 {
        return true
    }
    // Excessive camelCase transitions suggest minified code or CSS class dumps.
    if camelTransitions >= 6 && punctuationCount <= 1 {
        return true
    }
    // Multiple fused word-number-word patterns (e.g. "Items47Daring") suggest dense UI counters.
    let fusedMatches = text.matches(of: /[A-Za-z]{2,}\d{1,4}[A-Za-z]{2,}/)
    if fusedMatches.count >= 2 {
        return true
    }

    return false
}

func dedupeBlocks(_ input: [ReaderBlock]) -> [ReaderBlock] {
    var seen: Set<String> = []
    var output = [ReaderBlock]()
    for block in input {
        let fingerprint = String(describing: block)
        if seen.contains(fingerprint) { continue }
        seen.insert(fingerprint)
        output.append(block)
    }
    return output
}

func dedupeMedia(_ input: [MediaDescriptor]) -> [MediaDescriptor] {
    var seen: Set<String> = []
    return input.filter {
        if seen.contains($0.sourceURL) {
            return false
        }
        seen.insert($0.sourceURL)
        return true
    }
}

func dedupeEmbeds(_ input: [EmbedDescriptor]) -> [EmbedDescriptor] {
    var seen: Set<String> = []
    return input.filter {
        if seen.contains($0.embedURL) {
            return false
        }
        seen.insert($0.embedURL)
        return true
    }
}
