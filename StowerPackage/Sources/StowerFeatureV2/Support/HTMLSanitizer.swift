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
        if isLikelyBoilerplate(block, text: text) { continue }
        output.append(block)
    }

    return dedupeBlocks(output)
}

/// Drops a leading heading that just repeats the article title.
///
/// The reader renders its own header (title, site, author, date) above the
/// body, so a `<h1>` in the content saying the same thing shows the title
/// twice. Container-level removal handles the platforms whose header block is
/// recognisable by class; this is the catch-all for everything else.
///
/// Only the *first* heading is considered, and only when it matches the title —
/// a later section heading that happens to echo the title is left alone.
func removeLeadingTitleRepeat(
    _ blocks: [ReaderBlock],
    title: String,
    siteName: String? = nil,
    author: String? = nil
) -> [ReaderBlock] {
    // Everything the reader already prints in its own header. A leading block
    // that only restates one of these is furniture the page leaked, not prose:
    // the site name next to a logo, a bare byline, the headline again.
    let echoes = Set(
        ([title, siteName, author].compactMap { $0 })
            .map(comparableHeadingText)
            .filter { !$0.isEmpty }
    )
    guard !echoes.isEmpty else { return blocks }

    var output = blocks
    var index = 0
    // Only the run at the very top is considered, and only short blocks — a
    // real paragraph that happens to open with the site's name is kept.
    while index < output.count {
        switch output[index] {
        case .figure, .video:
            // A hero image may sit above the headline.
            index += 1
            continue
        case .heading(_, let inlines), .paragraph(let inlines):
            let text = inlineText(inlines)
            guard text.count <= 120, echoes.contains(comparableHeadingText(text)) else {
                return output
            }
            output.remove(at: index)
        default:
            return output
        }
    }
    return output
}

/// Lowercased, punctuation- and whitespace-insensitive form used to decide
/// whether a heading and the article title are "the same". Titles routinely
/// differ between `<title>`/og:title and the on-page `<h1>` by a trailing
/// site name, smart quotes, or an em dash.
private func comparableHeadingText(_ value: String) -> String {
    cleanText(value)
        .lowercased()
        .replacingOccurrences(of: "[\\p{Pd}]", with: "-", options: .regularExpression)
        .replacingOccurrences(of: "[\u{2018}\u{2019}\u{201C}\u{201D}]", with: "'", options: .regularExpression)
        .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
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

/// Applies the boilerplate heuristics with the block's own shape in mind.
///
/// The heuristics were written for paragraphs but were being applied to the
/// concatenation of a list's items, which is a completely different shape: a
/// bulleted list of eight short phrases trips "22+ tokens and no punctuation"
/// and the whole list disappeared from the article. Lists are judged per item
/// instead, and only discarded when *every* item looks like chrome. Headings
/// are short by nature and legitimately unpunctuated, so the word-count rule
/// does not apply to them at all.
func isLikelyBoilerplate(_ block: ReaderBlock, text: String) -> Bool {
    switch block {
    case .list(_, let items):
        let itemTexts = items.map(inlineText).filter { !$0.isEmpty }
        guard !itemTexts.isEmpty else { return true }
        return itemTexts.allSatisfy { isLikelyBoilerplateText($0) }
    case .heading:
        return isLikelyBoilerplateText(text, allowsUnpunctuatedProse: true)
    case .code:
        // Code is dense with digits, camelCase and no prose punctuation —
        // every one of these heuristics fires on a healthy code block.
        return false
    default:
        return isLikelyBoilerplateText(text)
    }
}

func isLikelyBoilerplateText(_ rawText: String, allowsUnpunctuatedProse: Bool = false) -> Bool {
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
    if !allowsUnpunctuatedProse && tokenCount >= 22 && punctuationCount == 0 {
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

/// Removes duplicate blocks.
///
/// Media blocks are deduplicated across the whole document — the same image
/// genuinely can be emitted twice by different parse paths. Text blocks are
/// only collapsed when they repeat *consecutively*: deduplicating those
/// globally deleted legitimately repeated prose (refrains, recurring section
/// labels, repeated short answers such as "Yes." / "No."), which left holes in
/// the article.
func dedupeBlocks(_ input: [ReaderBlock]) -> [ReaderBlock] {
    var seenMedia: Set<String> = []
    var output = [ReaderBlock]()
    for block in input {
        let fingerprint = String(describing: block)
        switch block {
        case .figure(let media), .video(let media):
            // Keyed on image identity rather than the whole block, so the same
            // photo at two CDN sizes (main carousel + thumbnail rail) collapses
            // to one figure instead of appearing large and then small.
            let key = mediaIdentity(media.sourceURL)
            if seenMedia.contains(key) { continue }
            seenMedia.insert(key)
        case .embed:
            if seenMedia.contains(fingerprint) { continue }
            seenMedia.insert(fingerprint)
        default:
            if let previous = output.last, String(describing: previous) == fingerprint { continue }
        }
        output.append(block)
    }
    return output
}

func dedupeMedia(_ input: [MediaDescriptor]) -> [MediaDescriptor] {
    var seen: Set<String> = []
    return input.filter {
        let key = mediaIdentity($0.sourceURL)
        if seen.contains(key) {
            return false
        }
        seen.insert(key)
        return true
    }
}

/// Identity of an image for duplicate detection, ignoring the resize/format
/// parameters image CDNs carry in the query string.
///
/// Galleries routinely emit the same photo twice — once in the main carousel
/// and once in the thumbnail rail — differing only by `?w=750` versus
/// `?w=1736`. Keying on the full URL treated those as two photos, so every
/// gallery appeared twice: once large, once small.
func mediaIdentity(_ sourceURL: String) -> String {
    guard let components = URLComponents(string: sourceURL) else { return sourceURL }
    guard let host = components.host, !components.path.isEmpty else { return sourceURL }
    // Some CDNs (Substack, Cloudinary) encode the original URL *inside* the
    // path, so the path alone still identifies the image uniquely.
    return host.lowercased() + components.path
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
