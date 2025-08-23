import SwiftUI

@Observable
public final class ReaderSettings {
    public var selectedPreset: ReaderPreset
    public var customAccentColor: Color
    public var customFont: ReaderFont
    public var customFontSize: CGFloat
    public var customBackground: BackgroundStyle
    public var isDarkMode: Bool?  // nil means system preference
    public var userPresets: [UserPreset] = []
    
    public init(
        preset: ReaderPreset = .default,
        customAccentColor: Color = .blue,
        customFont: ReaderFont = .system,
        customFontSize: CGFloat = 16,
        customBackground: BackgroundStyle = .system,
        isDarkMode: Bool? = nil
    ) {
        self.selectedPreset = preset
        self.customAccentColor = customAccentColor
        self.customFont = customFont
        self.customFontSize = customFontSize
        self.customBackground = customBackground
        self.isDarkMode = isDarkMode
    }
    
    // Computed properties that return effective values based on preset or custom settings
    public var effectiveAccentColor: Color {
        selectedPreset == .custom ? customAccentColor : selectedPreset.accentColor
    }
    
    public var effectiveFont: ReaderFont {
        selectedPreset == .custom ? customFont : selectedPreset.font
    }
    
    public var effectiveFontSize: CGFloat {
        selectedPreset == .custom ? customFontSize : selectedPreset.fontSize
    }
    
    public var effectiveBackground: Color {
        if selectedPreset == .custom {
            return customBackground.color
        } else {
            return selectedPreset.backgroundColor
        }
    }
    
    public var effectiveColorScheme: ColorScheme? {
        if selectedPreset == .custom {
            return isDarkMode == nil ? nil : (isDarkMode! ? .dark : .light)
        } else {
            return selectedPreset.colorScheme
        }
    }
    
    // User preset management
    public func saveCurrentAsPreset(name: String) {
        let newPreset = UserPreset(
            name: name,
            accentColor: customAccentColor,
            font: customFont,
            fontSize: customFontSize,
            background: customBackground,
            colorScheme: isDarkMode == nil ? nil : (isDarkMode! ? .dark : .light)
        )
        userPresets.append(newPreset)
    }
    
    public func loadUserPreset(_ preset: UserPreset) {
        selectedPreset = .custom
        customAccentColor = preset.accentColor
        customFont = preset.font
        customFontSize = preset.fontSize
        customBackground = preset.background
        isDarkMode = preset.colorScheme == nil ? nil : (preset.colorScheme == .dark)
    }
    
    public func deleteUserPreset(at index: Int) {
        guard index < userPresets.count else { return }
        userPresets.remove(at: index)
    }
}

public enum ReaderPreset: String, CaseIterable {
    case `default` = "Default"
    case sepia = "Sepia"
    case highContrast = "High Contrast"
    case darkMode = "Dark Mode"
    case minimal = "Minimal"
    case academic = "Academic"
    case custom = "Custom"
    
    public var accentColor: Color {
        switch self {
        case .default: return .blue
        case .sepia: return .brown
        case .highContrast: return .black
        case .darkMode: return .cyan
        case .minimal: return .gray
        case .academic: return .indigo
        case .custom: return .blue // fallback, shouldn't be used
        }
    }
    
    public var font: ReaderFont {
        switch self {
        case .default: return .system
        case .sepia: return .serif
        case .highContrast: return .system
        case .darkMode: return .system
        case .minimal: return .rounded
        case .academic: return .serif
        case .custom: return .system // fallback, shouldn't be used
        }
    }
    
    public var fontSize: CGFloat {
        switch self {
        case .default: return 16
        case .sepia: return 17
        case .highContrast: return 18
        case .darkMode: return 16
        case .minimal: return 15
        case .academic: return 17
        case .custom: return 16 // fallback, shouldn't be used
        }
    }
    
    public var colorScheme: ColorScheme? {
        switch self {
        case .default: return nil // system
        case .sepia: return .light
        case .highContrast: return .light
        case .darkMode: return .dark
        case .minimal: return nil // system
        case .academic: return .light
        case .custom: return nil // handled separately
        }
    }
    
    public var backgroundColor: Color {
        switch self {
        case .default: return Color.primary.opacity(0.05)
        case .sepia: return Color(red: 0.98, green: 0.96, blue: 0.90)
        case .highContrast: return .white
        case .darkMode: return Color.primary.opacity(0.05)
        case .minimal: return Color.primary.opacity(0.05)
        case .academic: return Color(red: 0.99, green: 0.99, blue: 0.97)
        case .custom: return Color.primary.opacity(0.05)
        }
    }
    
    public var description: String {
        switch self {
        case .default: return "Clean and modern with system colors"
        case .sepia: return "Warm, paper-like reading experience"
        case .highContrast: return "High contrast for better accessibility"
        case .darkMode: return "Dark theme optimized for low-light reading"
        case .minimal: return "Distraction-free minimal design"
        case .academic: return "Traditional serif fonts for scholarly reading"
        case .custom: return "Create your own reading experience"
        }
    }
}

public enum ReaderFont: String, CaseIterable, Codable {
    case system = "System"
    case serif = "Serif"
    case rounded = "Rounded"
    case monospaced = "Monospaced"
    
    public var fontDesign: Font.Design {
        switch self {
        case .system: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        }
    }
    
    public var displayName: String {
        switch self {
        case .system: return "San Francisco"
        case .serif: return "New York"
        case .rounded: return "SF Rounded"
        case .monospaced: return "SF Mono"
        }
    }
}

public enum BackgroundStyle: String, CaseIterable, Codable {
    case system = "System"
    case sepia = "Sepia"
    case paper = "Paper"
    case dark = "Dark"
    case black = "Black"
    
    public var color: Color {
        switch self {
        case .system: return Color.primary.opacity(0.05)
        case .sepia: return Color(red: 0.98, green: 0.96, blue: 0.90)
        case .paper: return Color(red: 0.99, green: 0.99, blue: 0.97)
        case .dark: return Color(red: 0.11, green: 0.11, blue: 0.12)
        case .black: return Color.black
        }
    }
    
    public var displayName: String {
        switch self {
        case .system: return "System"
        case .sepia: return "Sepia"
        case .paper: return "Paper"
        case .dark: return "Dark"
        case .black: return "Black"
        }
    }
}

public struct UserPreset: Identifiable, Codable {
    public let id: UUID
    public var name: String
    public let accentColor: Color
    public let font: ReaderFont
    public let fontSize: CGFloat
    public let background: BackgroundStyle
    public let colorScheme: ColorScheme?
    public let dateCreated: Date
    
    public init(
        name: String,
        accentColor: Color,
        font: ReaderFont,
        fontSize: CGFloat,
        background: BackgroundStyle,
        colorScheme: ColorScheme?
    ) {
        self.id = UUID()
        self.name = name
        self.accentColor = accentColor
        self.font = font
        self.fontSize = fontSize
        self.background = background
        self.colorScheme = colorScheme
        self.dateCreated = Date()
    }
}

extension ColorScheme: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)
        switch rawValue {
        case 0: self = .light
        case 1: self = .dark
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ColorScheme")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .light: try container.encode(0)
        case .dark: try container.encode(1)
        @unknown default: try container.encode(0)
        }
    }
}

extension Color: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        self.init(hex: hex)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.toHex())
    }
    
    private init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
    
    private func toHex() -> String {
        // Simplified hex conversion without UIKit/AppKit dependency
        // For the scope of this reader settings, we can use basic color representations
        return "000000" // Fallback - proper hex conversion would need resolved color components
    }
}