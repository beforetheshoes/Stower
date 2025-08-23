import SwiftUI
@preconcurrency import MarkdownUI

extension Theme {
    @MainActor static func stower(settings: ReaderSettings, screenWidth: CGFloat = 400) -> Theme {
        // Determine text color based on preset
        let textColor: Color = {
            switch settings.selectedPreset {
            case .sepia, .academic, .highContrast:
                return .black // Force black text for light backgrounds
            case .darkMode:
                return .white
            default:
                return Color.primary // System color
            }
        }()
        
        return Theme()
            .text {
                FontSize(.em(1.0))
                ForegroundColor(textColor)
                if settings.effectiveFont.fontDesign == .monospaced {
                    FontFamilyVariant(.monospaced)
                }
            }
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.25)) // Better line spacing for readability
                    .markdownMargin(top: .zero, bottom: .em(1.2)) // More space between paragraphs
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                ForegroundColor(settings.effectiveAccentColor)
                BackgroundColor(settings.effectiveAccentColor.opacity(0.1))
                // Add subtle padding and rounded corners for inline code
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .relativeLineSpacing(.em(0.3))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.9))
                        }
                        .padding(20)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(settings.effectiveAccentColor.opacity(0.2), lineWidth: 1)
                )
                .markdownMargin(top: .em(1.5), bottom: .em(1.5)) // Much more breathing room
            }
            .blockquote { configuration in
                HStack(alignment: .top, spacing: 16) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(settings.effectiveAccentColor)
                        .frame(width: 4)
                    
                    configuration.label
                        .relativeLineSpacing(.em(0.3))
                        .markdownTextStyle {
                            ForegroundColor(.secondary)
                            FontStyle(.italic)
                            if settings.effectiveFont.fontDesign == .monospaced {
                                FontFamilyVariant(.monospaced)
                            }
                        }
                        .padding(.vertical, 4)
                }
                .padding(.leading, 20)
                .markdownMargin(top: .em(1.5), bottom: .em(1.5)) // More space around blockquotes
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(2.2)) // Larger, more prominent
                        FontWeight(.bold)
                        ForegroundColor(settings.effectiveAccentColor)
                        if settings.effectiveFont.fontDesign == .monospaced {
                            FontFamilyVariant(.monospaced)
                        }
                    }
                    .markdownMargin(top: .em(2.0), bottom: .em(1.2)) // Much more space
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(1.8)) // Slightly larger
                        FontWeight(.bold)
                        ForegroundColor(settings.effectiveAccentColor.opacity(0.9))
                        if settings.effectiveFont.fontDesign == .monospaced {
                            FontFamilyVariant(.monospaced)
                        }
                    }
                    .markdownMargin(top: .em(1.8), bottom: .em(1.0)) // Better hierarchy
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(1.5))
                        FontWeight(.semibold)
                        ForegroundColor(settings.effectiveAccentColor.opacity(0.8))
                        if settings.effectiveFont.fontDesign == .monospaced {
                            FontFamilyVariant(.monospaced)
                        }
                    }
                    .markdownMargin(top: .em(1.5), bottom: .em(0.8))
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(1.3))
                        FontWeight(.semibold)
                        ForegroundColor(settings.effectiveAccentColor.opacity(0.7))
                        if settings.effectiveFont.fontDesign == .monospaced {
                            FontFamilyVariant(.monospaced)
                        }
                    }
                    .markdownMargin(top: .em(1.2), bottom: .em(0.6))
            }
            .heading5 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(1.1))
                        FontWeight(.medium)
                        ForegroundColor(settings.effectiveAccentColor.opacity(0.6))
                        if settings.effectiveFont.fontDesign == .monospaced {
                            FontFamilyVariant(.monospaced)
                        }
                    }
                    .markdownMargin(top: .em(1.0), bottom: .em(0.5))
            }
            .heading6 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(1.05))
                        FontWeight(.medium)
                        ForegroundColor(settings.effectiveAccentColor.opacity(0.5))
                        if settings.effectiveFont.fontDesign == .monospaced {
                            FontFamilyVariant(.monospaced)
                        }
                    }
                    .markdownMargin(top: .em(0.8), bottom: .em(0.4))
            }
            .link {
                ForegroundColor(settings.effectiveAccentColor)
            }
            .list { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.8), bottom: .em(1.2)) // Space around lists
            }
            .listItem { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        if settings.effectiveFont.fontDesign == .monospaced {
                            FontFamilyVariant(.monospaced)
                        }
                    }
                    .markdownMargin(top: .em(0.3), bottom: .em(0.3)) // Space between list items
            }
            .table { configuration in
                configuration.label
                    .markdownMargin(top: .em(1.5), bottom: .em(1.5)) // Space around tables
            }
            .thematicBreak {
                VStack(spacing: 0) {
                    Spacer().frame(height: 24) // More dramatic spacing
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                    Spacer().frame(height: 24)
                }
            }
    }
}