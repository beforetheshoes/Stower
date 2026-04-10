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
        case .newYork: return "NewYork"
        case .timesNewRoman: return "Times New Roman"
        case .helveticaNeue: return "Helvetica Neue"
        case .avenirNext: return "Avenir Next"
        case .menlo: return "Menlo"
        }
    }

    public var textAlignment: TextAlignment {
        switch justification {
        case .leading: return .leading
        case .justified: return .leading
        }
    }

    public var backgroundColor: Color {
        switch theme {
        case .white: return Color.white
        case .sepia: return Color(red: 0.96, green: 0.92, blue: 0.84)
        case .dark: return Color(red: 0.09, green: 0.10, blue: 0.12)
        }
    }

    public var surfaceColor: Color {
        switch theme {
        case .white: return Color(red: 0.95, green: 0.95, blue: 0.97)
        case .sepia: return Color(red: 0.91, green: 0.86, blue: 0.77)
        case .dark: return Color(red: 0.16, green: 0.17, blue: 0.20)
        }
    }

    public var primaryTextColor: Color {
        switch theme {
        case .white, .sepia: return Color(red: 0.12, green: 0.12, blue: 0.14)
        case .dark: return Color(red: 0.92, green: 0.92, blue: 0.94)
        }
    }

    public var secondaryTextColor: Color {
        switch theme {
        case .white, .sepia: return Color(red: 0.36, green: 0.36, blue: 0.40)
        case .dark: return Color(red: 0.68, green: 0.68, blue: 0.72)
        }
    }

    var italicFamilyName: String {
        switch fontStyle {
        case .newYork: return "NewYork-Italic"
        case .timesNewRoman: return "Times New Roman Italic"
        case .helveticaNeue: return "HelveticaNeue-Italic"
        case .avenirNext: return "AvenirNext-Italic"
        case .menlo: return "Menlo-Italic"
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
            case 1: multiplier = 2.05
            case 2: multiplier = 1.65
            case 3: multiplier = 1.4
            default: multiplier = 1.2
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
        case .blockquote: return UIColor(secondaryTextColor)
        case .body, .list, .heading: return UIColor(primaryTextColor)
        }
        #elseif canImport(AppKit)
        switch role {
        case .blockquote: return NSColor(secondaryTextColor)
        case .body, .list, .heading: return NSColor(primaryTextColor)
        }
        #endif
    }

    /// Reader-aware CSS for archived webView content.
    /// Applies reader font, size, color, and layout to text elements while
    /// leaving interactive elements (SVGs, canvas, video) untouched.
    public func readerOverlayCSS(pageWidth: CGFloat) -> String {
        let bgHex = cssHex(backgroundColor)
        let textHex = cssHex(primaryTextColor)
        let secondaryHex = cssHex(secondaryTextColor)
        let surfHex = cssHex(surfaceColor)
        let font = cssFont
        let lineH = 1.4 + lineSpacing / 20
        let columnWidth = min(lineWidth, pageWidth - 40)

        return """
        :root {
          color-scheme: \(theme == .dark ? "dark" : "light");
        }

        /* Reset backgrounds and colors to reader theme.
           Avoid targeting generic `div` — it breaks SVG container sizing. */
        html, body, main, article, section, aside,
        .content, .page, .post, .entry, .container, .wrapper,
        [role="main"], [role="article"],
        .md-main, .md-content {
          background-color: \(bgHex) !important;
          color: \(textHex) !important;
        }
        html {
          overflow-x: hidden !important;
        }
        body {
          font-family: \(font), -apple-system, serif !important;
          font-size: \(fontSize)px !important;
          line-height: \(lineH) !important;
          max-width: \(columnWidth)px !important;
          margin: 0 auto !important;
          padding: 20px 20px 60px 20px !important;
          word-break: break-word;
          overflow-x: hidden !important;
        }

        /* Block-level text elements — apply full reader styling (font, size, color).
           These set the base style that inline elements inherit.
           Exclude elements inside interactive widgets ([role="figure"]) and SVGs. */
        :is(p, li, td, th, dd, dt, figcaption, label):not([role="figure"] *):not(svg *),
        .md-typeset:not([role="figure"] *), .md-content:not([role="figure"] *),
        .article-body:not([role="figure"] *), .post-content:not([role="figure"] *),
        .entry-content:not([role="figure"] *) {
          font-family: \(font), -apple-system, serif !important;
          font-size: \(fontSize)px !important;
          line-height: \(lineH) !important;
          color: \(textHex) !important;
        }

        /* Inline elements — font and size only, NO color override.
           Color is inherited from parent block elements, so article text
           gets the reader color while widget spans keep their original
           explicit colors (e.g. Tailwind text-amber-600). */
        :is(span, em, strong, b, i):not([role="figure"] *):not(svg *) {
          font-family: inherit !important;
          font-size: inherit !important;
          line-height: inherit !important;
        }

        :is(h1, h2, h3, h4, h5, h6):not([role="figure"] *):not(svg *) {
          font-family: \(font), -apple-system, serif !important;
          color: \(textHex) !important;
          line-height: 1.25 !important;
        }
        h1:not([role="figure"] *) { font-size: \(fontSize * 2.05)px !important; }
        h2:not([role="figure"] *) { font-size: \(fontSize * 1.65)px !important; }
        h3:not([role="figure"] *) { font-size: \(fontSize * 1.4)px !important; }
        h4:not([role="figure"] *), h5:not([role="figure"] *), h6:not([role="figure"] *) { font-size: \(fontSize * 1.2)px !important; }
        a:not([role="figure"] *):not(svg *) { color: \(cssAccentColor) !important; }
        blockquote:not([role="figure"] *):not(svg *) {
          border-left: 4px solid \(secondaryHex) !important;
          padding-left: 12px !important;
          color: \(secondaryHex) !important;
          background-color: transparent !important;
        }
        pre:not([role="figure"] *):not(svg *), code:not([role="figure"] *):not(svg *) {
          background: \(surfHex) !important;
          border-radius: 6px;
          color: \(textHex) !important;
        }
        table { width: 100% !important; border-collapse: collapse; }
        td, th {
          border: 1px solid \(secondaryHex) !important;
          padding: 6px 10px;
          background-color: \(bgHex) !important;
        }

        /* Images — constrain but don't restyle */
        img { max-width: 100% !important; height: auto !important; border-radius: 8px; }

        /* Interactive elements — no overrides needed.
           All text styling rules above already exclude [role="figure"] *
           and svg * via :not() selectors, so nothing leaks in.
           Font-family/size DO inherit from body, but widgets typically
           set their own fonts explicitly (e.g. font-mono class), so
           inheritance is overridden by the widget's own CSS. */

        /* Hide navigation clutter */
        nav, header, footer, .sidebar, .comments, .share, .related,
        [role="banner"], [role="navigation"], [role="contentinfo"],
        .md-header, .md-footer, .md-tabs, .md-sidebar, .md-search,
        .navbar, .nav-bar, .site-header, .site-footer, .site-nav,
        .top-bar, .bottom-bar, .cookie-banner, .newsletter-signup,
        .social-share, .author-bio, .related-posts {
          display: none !important;
        }
        """
    }

    /// CSS string that applies the reader theme to a WebView.
    public func readerCSS(pageWidth: CGFloat) -> String {
        let bgHex = cssHex(backgroundColor)
        let textHex = cssHex(primaryTextColor)
        let secondaryHex = cssHex(secondaryTextColor)
        let font = cssFont
        let columnWidth = min(lineWidth, pageWidth - 40)

        return """
        :root {
          color-scheme: \(theme == .dark ? "dark" : "light");
        }
        html, body {
          background-color: \(bgHex) !important;
          color: \(textHex) !important;
          font-family: \(font), -apple-system, serif !important;
          font-size: \(fontSize)px !important;
          line-height: \(1.4 + lineSpacing / 20) !important;
          max-width: \(columnWidth)px !important;
          margin: 0 auto !important;
          padding: 20px 20px 60px 20px !important;
          word-break: break-word;
        }
        a { color: \(cssAccentColor) !important; }
        pre, code { background: \(cssHex(surfaceColor)) !important; border-radius: 6px; }
        blockquote { border-left: 4px solid \(secondaryHex); padding-left: 12px; color: \(secondaryHex) !important; }
        img { max-width: 100% !important; height: auto !important; border-radius: 8px; }
        table { width: 100% !important; border-collapse: collapse; }
        td, th { border: 1px solid \(secondaryHex); padding: 6px 10px; }
        nav, header, footer, .sidebar, .comments, .share, .related, [role="banner"], [role="navigation"] {
          display: none !important;
        }
        """
    }

    private var cssFont: String {
        switch fontStyle {
        case .newYork: return "'New York'"
        case .timesNewRoman: return "'Times New Roman'"
        case .helveticaNeue: return "'Helvetica Neue'"
        case .avenirNext: return "'Avenir Next'"
        case .menlo: return "Menlo"
        }
    }

    private var cssAccentColor: String {
        switch theme {
        case .white: return "#0066cc"
        case .sepia: return "#5c3d11"
        case .dark: return "#4da6ff"
        }
    }

    private func cssHex(_ color: Color) -> String {
        #if canImport(UIKit)
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
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
        case .blockquote: return true
        case .body, .list, .heading: return false
        }
    }
}

extension ReaderJustification {
    public var displayName: String {
        switch self {
        case .leading: return "Left"
        case .justified: return "Justified"
        }
    }
}

extension ReaderTheme {
    public var displayName: String {
        switch self {
        case .white: return "White"
        case .sepia: return "Sepia"
        case .dark: return "Dark"
        }
    }
}
