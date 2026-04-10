import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Shared between rendering and speech so the displayed text and spoken text stay byte-for-byte aligned.
enum ReaderTextLayoutSupport {
    private static let minimumLayoutWidth: CGFloat = 120
    private static let defaultFallbackWidth: CGFloat = 320

    static func makeInlineAttributedString(from inlines: [ReaderInline]) -> AttributedString {
        var output = AttributedString("")
        var previousScalar: Character?

        for inline in inlines {
            let segment = attributedSegment(for: inline)
            guard !segment.characters.isEmpty else { continue }

            if let nextScalar = segment.characters.first, shouldInsertSpace(previous: previousScalar, next: nextScalar) {
                output += AttributedString(" ")
            }
            output += segment
            previousScalar = segment.characters.last
        }

        return output
    }

    static func inlinePlainText(from inlines: [ReaderInline]) -> String {
        String(makeInlineAttributedString(from: inlines).characters)
    }

    static func listSpeechTextAndRanges(items: [[ReaderInline]]) -> (text: String, itemRanges: [NSRange]) {
        var itemRanges: [NSRange] = []
        var pieces: [String] = []
        pieces.reserveCapacity(items.count)

        var cursorUTF16 = 0
        for item in items {
            let text = inlinePlainText(from: item)
            pieces.append(text)

            let length = (text as NSString).length
            itemRanges.append(NSRange(location: cursorUTF16, length: length))
            cursorUTF16 += length

            // Use a newline separator so both speech and highlight mapping are stable.
            cursorUTF16 += ("\n" as NSString).length
        }

        return (pieces.joined(separator: "\n"), itemRanges)
    }

    static func layoutWidths(proposedWidth: CGFloat?, fallbackWidth: CGFloat?) -> (reported: CGFloat, measurement: CGFloat) {
        if let proposedWidth, proposedWidth.isFinite, proposedWidth > 0 {
            let width = max(proposedWidth, minimumLayoutWidth)
            return (reported: width, measurement: width)
        }
        if let fallbackWidth, fallbackWidth.isFinite, fallbackWidth > 0 {
            let width = max(fallbackWidth, minimumLayoutWidth)
            return (reported: 0, measurement: width)
        }
        return (reported: 0, measurement: defaultFallbackWidth)
    }

    static func measuredHeight(for attributedText: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        let usedRect = layoutManager.usedRect(for: container)
        return max(1, ceil(usedRect.height))
    }

    private static func attributedSegment(for inline: ReaderInline) -> AttributedString {
        switch inline {
        case .text(let value):
            return AttributedString(value)
        case .link(let label, let url):
            var link = AttributedString(label)
            link.link = URL(string: url)
            return link
        case .emphasis(let value):
            var piece = AttributedString(value)
            piece.inlinePresentationIntent = .emphasized
            return piece
        case .strong(let value):
            var piece = AttributedString(value)
            piece.inlinePresentationIntent = .stronglyEmphasized
            return piece
        case .code(let value):
            var piece = AttributedString(value)
            piece.inlinePresentationIntent = .code
            return piece
        case .strikethrough(let value):
            var piece = AttributedString(value)
            piece.strikethroughStyle = .single
            return piece
        }
    }

    private static func shouldInsertSpace(previous: Character?, next: Character) -> Bool {
        guard let previous else { return false }
        if previous.isWhitespace || next.isWhitespace { return false }

        let noLeadingSpaceBefore: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "]", "}", "”", "’", "%"]
        if noLeadingSpaceBefore.contains(next) { return false }

        let noTrailingSpaceAfter: Set<Character> = ["(", "[", "{", "“", "‘", "/", "-"]
        if noTrailingSpaceAfter.contains(previous) { return false }

        return true
    }
}

