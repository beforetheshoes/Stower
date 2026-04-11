import Foundation

/// Raw Flexoki palette values, sourced directly from https://stephango.com/flexoki.
///
/// This file is deliberately UI-framework-free: it only exposes hex strings so
/// it can live in `StowerData` (which does not depend on SwiftUI). The
/// SwiftUI-facing `FlexokiPalette` in `StowerFeatureV2` reads from here.
///
/// The full 50–950 ramp is preserved for every hue so future features (charts,
/// highlight colors, chart grid lines) can pick the exact shade they need.
public enum FlexokiRaw {
    // MARK: - Base (warm monochromatic)

    /// Flexoki's `paper` value — the default warm cream background.
    public static let paper = "#FFFCF0"
    /// Flexoki's `black` value — the deepest ink shade.
    public static let black = "#100F0F"

    /// Numbered warm-grey ramp, light → dark.
    public static let base: [Int: String] = [
        50:  "#F2F0E5",
        100: "#E6E4D9",
        150: "#DAD8CE",
        200: "#CECDC3",
        300: "#B7B5AC",
        400: "#9F9D96",
        500: "#878580",
        600: "#6F6E69",
        700: "#575653",
        800: "#403E3C",
        850: "#343331",
        900: "#282726",
        950: "#1C1B1A",
    ]

    // MARK: - Accent ramps (50–950) for each Flexoki hue

    public static let red: [Int: String] = [
        50:  "#FFE1D5", 100: "#FFCABB", 150: "#FDB2A2", 200: "#F89A8A",
        300: "#E8705F", 400: "#D14D41", 500: "#C03E35", 600: "#AF3029",
        700: "#942822", 800: "#6C201C", 850: "#551B18", 900: "#3E1715",
        950: "#261312",
    ]

    public static let orange: [Int: String] = [
        50:  "#FFE7CE", 100: "#FED3AF", 150: "#FCC192", 200: "#F9AE77",
        300: "#EC8B49", 400: "#DA702C", 500: "#CB6120", 600: "#BC5215",
        700: "#9D4310", 800: "#71320D", 850: "#59290D", 900: "#40200D",
        950: "#27180E",
    ]

    public static let yellow: [Int: String] = [
        50:  "#FAEEC6", 100: "#F6E2A0", 150: "#F1D67E", 200: "#ECCB60",
        300: "#DFB431", 400: "#D0A215", 500: "#BE9207", 600: "#AD8301",
        700: "#8E6B01", 800: "#664D01", 850: "#503D02", 900: "#3A2D04",
        950: "#241E08",
    ]

    public static let green: [Int: String] = [
        50:  "#EDEECF", 100: "#DDE2B2", 150: "#CDD597", 200: "#BEC97E",
        300: "#A0AF54", 400: "#879A39", 500: "#768D21", 600: "#66800B",
        700: "#536907", 800: "#3D4C07", 850: "#313D07", 900: "#252D09",
        950: "#1A1E0C",
    ]

    public static let cyan: [Int: String] = [
        50:  "#DDF1E4", 100: "#BFE8D9", 150: "#A2DECE", 200: "#87D3C3",
        300: "#5ABDAC", 400: "#3AA99F", 500: "#2F968D", 600: "#24837B",
        700: "#1C6C66", 800: "#164F4A", 850: "#143F3C", 900: "#122F2C",
        950: "#101F1D",
    ]

    public static let blue: [Int: String] = [
        50:  "#E1ECEB", 100: "#C6DDE8", 150: "#ABCFE2", 200: "#92BFDB",
        300: "#66A0C8", 400: "#4385BE", 500: "#3171B2", 600: "#205EA6",
        700: "#1A4F8C", 800: "#163B66", 850: "#133051", 900: "#12253B",
        950: "#101A24",
    ]

    public static let purple: [Int: String] = [
        50:  "#F0EAEC", 100: "#E2D9E9", 150: "#D3CAE6", 200: "#C4B9E0",
        300: "#A699D0", 400: "#8B7EC8", 500: "#735EB5", 600: "#5E409D",
        700: "#4F3685", 800: "#3C2A62", 850: "#31234E", 900: "#261C39",
        950: "#1A1623",
    ]

    public static let magenta: [Int: String] = [
        50:  "#FEE4E5", 100: "#FCCFDA", 150: "#F9B9CF", 200: "#F4A4C2",
        300: "#E47DA8", 400: "#CE5D97", 500: "#B74583", 600: "#A02F6F",
        700: "#87285E", 800: "#641F46", 850: "#4F1B39", 900: "#39172B",
        950: "#24131D",
    ]

    /// Look up a hue's ramp by the `FlexokiHue` case.
    public static func ramp(for hue: FlexokiHue) -> [Int: String] {
        switch hue {
        case .red: return red
        case .orange: return orange
        case .yellow: return yellow
        case .green: return green
        case .cyan: return cyan
        case .blue: return blue
        case .purple: return purple
        case .magenta: return magenta
        }
    }

    /// Safe indexed lookup — returns the ramp value for the given level, or a
    /// sensible neighbour if the level is missing (should never happen with
    /// the tables above, but this keeps call sites total).
    public static func shade(_ hue: FlexokiHue, _ level: Int) -> String {
        ramp(for: hue)[level] ?? ramp(for: hue)[600] ?? "#000000"
    }

    // MARK: - Background tokens
    //
    // Each `ReaderBackground` resolves to a coordinated set of warm-tone
    // surface/text/border values. The three light backgrounds share the
    // Flexoki monochromatic base values; `sepia` uses custom warmer tones
    // tuned to sit between `paper` and the `orange-100` shade without
    // clashing with any of the 8 accent hues.

    public struct BackgroundTokens: Sendable, Equatable {
        public let bg: String
        public let bg2: String
        public let ui: String
        public let ui2: String
        public let ui3: String
        public let tx: String
        public let tx2: String
        public let tx3: String
        public let isDark: Bool
    }

    public static func tokens(for background: ReaderBackground) -> BackgroundTokens {
        switch background {
        case .paper:
            return BackgroundTokens(
                bg:  paper,
                bg2: base[50]!,
                ui:  base[100]!,
                ui2: base[150]!,
                ui3: base[200]!,
                tx:  black,
                tx2: base[600]!,
                tx3: base[300]!,
                isDark: false
            )
        case .white:
            return BackgroundTokens(
                bg:  "#FFFFFF",
                bg2: base[50]!,
                ui:  base[100]!,
                ui2: base[150]!,
                ui3: base[200]!,
                tx:  black,
                tx2: base[600]!,
                tx3: base[300]!,
                isDark: false
            )
        case .sepia:
            // Custom warm-cream palette tuned to feel like aged paper. These
            // values sit between Flexoki's `paper` and `orange-100` and
            // intentionally carry more yellow than the cool `base` ramp so
            // accent hues feel grounded in the same warm light.
            return BackgroundTokens(
                bg:  "#F4EBD4",
                bg2: "#EBDFC2",
                ui:  "#DCCFAD",
                ui2: "#D1C29A",
                ui3: "#C4B280",
                tx:  base[950]!,
                tx2: base[700]!,
                tx3: base[500]!,
                isDark: false
            )
        case .black:
            return BackgroundTokens(
                bg:  base[950]!,
                bg2: base[900]!,
                ui:  base[850]!,
                ui2: base[800]!,
                ui3: base[700]!,
                tx:  base[200]!,
                tx2: base[500]!,
                tx3: base[700]!,
                isDark: true
            )
        }
    }

    // MARK: - Accent shade mapping
    //
    // Flexoki's guidance: light themes should anchor accents on the `600`
    // shade, dark themes on `400`. We derive hover/fill/wash shades in the
    // same pattern for consistency across both modes.

    public struct AccentShades: Sendable, Equatable {
        public let main: String
        public let muted: String
        public let fill: String
        public let wash: String
    }

    public static func accent(_ hue: FlexokiHue, isDark: Bool) -> AccentShades {
        if isDark {
            return AccentShades(
                main:  shade(hue, 400),
                muted: shade(hue, 300),
                fill:  shade(hue, 800),
                wash:  shade(hue, 900)
            )
        } else {
            return AccentShades(
                main:  shade(hue, 600),
                muted: shade(hue, 700),
                fill:  shade(hue, 100),
                wash:  shade(hue, 50)
            )
        }
    }
}
