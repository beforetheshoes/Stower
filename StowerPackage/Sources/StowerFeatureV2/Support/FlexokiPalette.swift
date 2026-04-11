import SwiftUI
import StowerData

/// A fully-resolved palette of SwiftUI colors for a given
/// `(background, primaryAccent, secondaryAccent)` triple. Every view in the
/// app reads from this type via `@Environment(\.flexokiPalette)` (see
/// `FlexokiEnvironment.swift`) so there is exactly one place that maps the
/// user's appearance choices into `Color` values.
///
/// Raw hex values come from `FlexokiRaw` in `StowerData` so the data layer
/// stays UI-framework-free.
public struct FlexokiPalette: Equatable, Sendable {
    // Base
    public let bg: Color           // main background
    public let bg2: Color          // surfaces, cards, code blocks, toolbar
    public let ui: Color           // borders, dividers
    public let ui2: Color          // hovered borders, selected row bg
    public let ui3: Color          // pressed/active borders
    public let tx: Color           // primary text
    public let tx2: Color          // muted text
    public let tx3: Color          // faint text

    // Primary accent
    public let primary: Color       // main accent — links, tint, active states
    public let primaryMuted: Color  // hover/secondary shade
    public let primaryFill: Color   // pill/badge fills
    public let primaryWash: Color   // very subtle backgrounds / selections

    // Secondary accent
    public let secondary: Color
    public let secondaryMuted: Color
    public let secondaryFill: Color
    public let secondaryWash: Color

    // Semantic (always their canonical hue, remapped to match light/dark)
    public let error: Color
    public let warning: Color
    public let success: Color
    public let info: Color

    public let colorScheme: ColorScheme
    public let isDark: Bool

    // MARK: - Raw hex accessors
    //
    // Views that need to render colors outside SwiftUI (reader CSS, SVG,
    // attributed strings) read hex strings so they skip a UIColor round-trip
    // that is often lossy in the sRGB→device colourspace conversion.

    public let bgHex: String
    public let bg2Hex: String
    public let uiHex: String
    public let txHex: String
    public let tx2Hex: String
    public let tx3Hex: String
    public let primaryHex: String
    public let primaryMutedHex: String
    public let primaryWashHex: String
    public let secondaryHex: String
    public let secondaryMutedHex: String

    // MARK: - Resolver

    public static func resolve(
        background: ReaderBackground,
        primaryAccent: FlexokiHue,
        secondaryAccent: FlexokiHue
    ) -> FlexokiPalette {
        let base = FlexokiRaw.tokens(for: background)
        let primary = FlexokiRaw.accent(primaryAccent, isDark: base.isDark)
        let secondary = FlexokiRaw.accent(secondaryAccent, isDark: base.isDark)
        // Semantic tokens always pick the canonical hue at the appropriate shade.
        let error = FlexokiRaw.accent(.red, isDark: base.isDark)
        let warning = FlexokiRaw.accent(.yellow, isDark: base.isDark)
        let success = FlexokiRaw.accent(.green, isDark: base.isDark)
        let info = FlexokiRaw.accent(.blue, isDark: base.isDark)

        return FlexokiPalette(
            bg:            Color(hex: base.bg),
            bg2:           Color(hex: base.bg2),
            ui:            Color(hex: base.ui),
            ui2:           Color(hex: base.ui2),
            ui3:           Color(hex: base.ui3),
            tx:            Color(hex: base.tx),
            tx2:           Color(hex: base.tx2),
            tx3:           Color(hex: base.tx3),
            primary:       Color(hex: primary.main),
            primaryMuted:  Color(hex: primary.muted),
            primaryFill:   Color(hex: primary.fill),
            primaryWash:   Color(hex: primary.wash),
            secondary:     Color(hex: secondary.main),
            secondaryMuted: Color(hex: secondary.muted),
            secondaryFill: Color(hex: secondary.fill),
            secondaryWash: Color(hex: secondary.wash),
            error:         Color(hex: error.main),
            warning:       Color(hex: warning.main),
            success:       Color(hex: success.main),
            info:          Color(hex: info.main),
            colorScheme:   base.isDark ? .dark : .light,
            isDark:        base.isDark,
            bgHex:         base.bg,
            bg2Hex:        base.bg2,
            uiHex:         base.ui,
            txHex:         base.tx,
            tx2Hex:        base.tx2,
            tx3Hex:        base.tx3,
            primaryHex:    primary.main,
            primaryMutedHex: primary.muted,
            primaryWashHex: primary.wash,
            secondaryHex:  secondary.main,
            secondaryMutedHex: secondary.muted
        )
    }

    /// The default palette used when nothing is in the environment yet (e.g.
    /// SwiftUI previews, the initial frame before the database read completes).
    public static let `default` = FlexokiPalette.resolve(
        background: .paper,
        primaryAccent: .blue,
        secondaryAccent: .purple
    )
}

// MARK: - ReaderAppearanceSettings bridge

extension ReaderAppearanceSettings {
    /// The fully-resolved palette for this appearance choice. Recomputed on
    /// demand — `FlexokiPalette` is a cheap value type so there is no benefit
    /// to caching it.
    public var palette: FlexokiPalette {
        FlexokiPalette.resolve(
            background: background,
            primaryAccent: primaryAccent,
            secondaryAccent: secondaryAccent
        )
    }
}

// MARK: - Color(hex:) helper
//
// SwiftUI's `Color` doesn't ship with a hex-string initializer. Flexoki only
// uses 6-digit `#RRGGBB` values so this parser is deliberately narrow — any
// malformed input falls through to magenta so the failure is obvious during
// development.

extension Color {
    init(hex: String) {
        var cleaned = hex
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6,
              let rgb = UInt32(cleaned, radix: 16)
        else {
            self = .pink
            return
        }
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >> 8) / 255
        let b = Double(rgb & 0x0000FF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
