import Foundation
#if canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#endif
import StowerData
import SwiftUI

extension ReaderAppearanceSettings {
    public var bodyFont: Font {
        .custom(familyName, size: fontSize, relativeTo: .body)
    }

    public var listFont: Font {
        .custom(familyName, size: max(fontSize - 1, 12), relativeTo: .body)
    }

    public var codeFont: Font {
        .custom("Menlo", size: max(fontSize - 3, 11), relativeTo: .footnote)
    }

    public func headingFont(for level: Int, baseSize: Double) -> Font {
        let multiplier: Double
        let weight: Font.Weight

        switch level {
        case 1:
            multiplier = 2.05
            weight = .bold
        case 2:
            multiplier = 1.65
            weight = .semibold
        case 3:
            multiplier = 1.4
            weight = .semibold
        default:
            multiplier = 1.2
            weight = .semibold
        }

        return .custom(familyName, size: max(baseSize * multiplier, 14), relativeTo: .title).weight(weight)
    }

    public var familyName: String {
        switch fontStyle {
        case .newYork:
            return "NewYork"
        case .timesNewRoman:
            return "Times New Roman"
        case .helveticaNeue:
            return "Helvetica Neue"
        case .avenirNext:
            return "Avenir Next"
        case .menlo:
            return "Menlo"
        }
    }

    public var textAlignment: TextAlignment {
        switch justification {
        case .leading:
            return .leading
        case .justified:
            return .leading
        }
    }

    // MARK: - Color tokens (palette forwards)
    //
    // Every color used by the reader screen comes from the Flexoki palette
    // resolved from `background/primaryAccent/secondaryAccent`. The
    // convenience properties below keep existing call sites compiling while
    // routing through a single source of truth.

    public var backgroundColor: Color { palette.bg }
    public var surfaceColor: Color { palette.bg2 }
    public var primaryTextColor: Color { palette.tx }
    public var secondaryTextColor: Color { palette.tx2 }
    public var faintTextColor: Color { palette.tx3 }
    public var borderColor: Color { palette.ui }
    public var accentColor: Color { palette.primary }

    var italicFamilyName: String {
        switch fontStyle {
        case .newYork:
            return "NewYork-Italic"
        case .timesNewRoman:
            return "Times New Roman Italic"
        case .helveticaNeue:
            return "HelveticaNeue-Italic"
        case .avenirNext:
            return "AvenirNext-Italic"
        case .menlo:
            return "Menlo-Italic"
        }
    }

    public func platformFont(for role: ReaderInlineTextRole, baseSize: Double) -> PlatformFont {
        let family = role.isItalic ? italicFamilyName : familyName
        let size: CGFloat
        switch role {
        case .body:
            size = baseSize
        case .list:
            size = max(baseSize - 1, 12)
        case .blockquote:
            size = baseSize
        case .heading(let level):
            let multiplier: Double
            switch level {
            case 1:
                multiplier = 2.05
            case 2:
                multiplier = 1.65
            case 3:
                multiplier = 1.4
            default:
                multiplier = 1.2
            }
            size = max(baseSize * multiplier, 14)
        }
        #if canImport(UIKit)
        return UIFont(name: family, size: size) ?? UIFont.systemFont(ofSize: size)
        #elseif canImport(AppKit)
        return NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size)
        #endif
    }

    public func platformTextColor(for role: ReaderInlineTextRole) -> PlatformColor {
        #if canImport(UIKit)
        switch role {
        case .blockquote:
            return UIColor(secondaryTextColor)
        case .body, .list, .heading:
            return UIColor(primaryTextColor)
        }
        #elseif canImport(AppKit)
        switch role {
        case .blockquote:
            return NSColor(secondaryTextColor)
        case .body, .list, .heading:
            return NSColor(primaryTextColor)
        }
        #endif
    }

    /// CSS string that applies the reader theme to a WebView. All colors are
    /// exposed as CSS custom properties so the shared `<style>` template
    /// reads exactly like the native palette tokens.
    public func readerCSS(pageWidth: CGFloat, fontScale: Double = 1) -> String {
        let p = palette
        let font = cssFont
        let policy = ReaderLineWidthPolicy(viewportWidth: Double(pageWidth))
        let columnWidth = policy.clamped(lineWidth)
        let colorScheme = p.isDark ? "dark" : "light"

        return """
        :root {
          color-scheme: \(colorScheme);
          --stower-bg: \(p.bgHex);
          --stower-bg2: \(p.bg2Hex);
          --stower-ui: \(p.uiHex);
          --stower-tx: \(p.txHex);
          --stower-tx2: \(p.tx2Hex);
          --stower-tx3: \(p.tx3Hex);
          --stower-primary: \(p.primaryHex);
          --stower-primary-muted: \(p.primaryMutedHex);
          --stower-primary-wash: \(p.primaryWashHex);
          --stower-secondary: \(p.secondaryHex);
          --stower-secondary-muted: \(p.secondaryMutedHex);
        }
        html, body {
          background-color: var(--stower-bg) !important;
          color: var(--stower-tx) !important;
          font-family: \(font), -apple-system, serif !important;
          font-size: \(fontSize * max(fontScale, 0.75))px !important;
          line-height: \(1.4 + lineSpacing / 20) !important;
          width: 100% !important;
          max-width: 100% !important;
          margin: 0 !important;
          overflow-x: hidden !important;
          overscroll-behavior-x: none !important;
          touch-action: pan-y pinch-zoom !important;
          word-break: break-word;
          text-align: \(justification == .justified ? "justify" : "left") !important;
        }
        body {
          padding: 20px 20px 60px 20px !important;
          box-sizing: border-box !important;
        }
        .stower-article {
          width: 100% !important;
          max-width: \(columnWidth)px !important;
          margin: 0 auto !important;
          overflow-x: clip !important;
        }
        a { color: var(--stower-primary) !important; text-decoration-color: color-mix(in srgb, var(--stower-primary) 45%, transparent); }
        a:hover { color: var(--stower-primary-muted) !important; }
        pre, code { background: var(--stower-bg2) !important; color: var(--stower-tx) !important; border-radius: 6px; }
        pre { padding: 12px; overflow-x: auto; }
        code { padding: 0 4px; }
        blockquote {
          border-left: 4px solid var(--stower-secondary);
          padding-left: 14px;
          margin-left: 0;
          color: var(--stower-tx2) !important;
          font-style: italic;
        }
        hr { border: none; border-top: 1px solid var(--stower-ui); margin: 2em 0; }
        h1, h2, h3, h4, h5, h6 { color: var(--stower-tx) !important; }
        h1 { border-bottom: 1px solid var(--stower-ui); padding-bottom: 0.25em; }
        h2 { border-bottom: 1px solid var(--stower-ui); padding-bottom: 0.2em; }
        img { max-width: 100% !important; height: auto !important; border-radius: 8px; }
        table { width: 100% !important; border-collapse: collapse; }
        td, th { border: 1px solid var(--stower-ui); padding: 6px 10px; color: var(--stower-tx); }
        th { background: var(--stower-bg2); }
        ::selection { background: var(--stower-primary-wash); color: var(--stower-tx); }
        nav, header:not(.stower-header), footer, .sidebar, .comments, .share, .related, [role="banner"], [role="navigation"] {
          display: none !important;
        }
        """
    }

    private var cssFont: String {
        switch fontStyle {
        case .newYork:
            return "'New York'"
        case .timesNewRoman:
            return "'Times New Roman'"
        case .helveticaNeue:
            return "'Helvetica Neue'"
        case .avenirNext:
            return "'Avenir Next'"
        case .menlo:
            return "Menlo"
        }
    }
}

/// Role enum exposed for use across Reader files.
public enum ReaderInlineTextRole: Equatable {
    case body
    case list
    case blockquote
    case heading(level: Int)

    public var isItalic: Bool {
        switch self {
        case .blockquote:
            return true
        case .body, .list, .heading:
            return false
        }
    }
}

extension ReaderJustification {
    public var displayName: String {
        switch self {
        case .leading:
            return "Left"
        case .justified:
            return "Justified"
        }
    }
}
