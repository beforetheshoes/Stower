import SwiftUI

struct CalloutView: View {
    let type: CalloutType
    let content: String
    let readerSettings: ReaderSettings
    
    private var effectiveColor: Color {
        // Use accent color for callouts when in custom mode, otherwise use type-specific color
        readerSettings.selectedPreset == .custom ? readerSettings.effectiveAccentColor : type.color
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) { // More spacing between icon and content
            Image(systemName: type.icon)
                .foregroundColor(effectiveColor)
                .font(.system(size: readerSettings.effectiveFontSize, weight: .medium, design: readerSettings.effectiveFont.fontDesign))
                .frame(width: 24) // Slightly larger icon area
            
            VStack(alignment: .leading, spacing: 8) { // More spacing between title and content
                Text(type.rawValue)
                    .font(.system(size: readerSettings.effectiveFontSize - 4, design: readerSettings.effectiveFont.fontDesign))
                    .fontWeight(.semibold)
                    .foregroundColor(effectiveColor)
                    .textCase(.uppercase)
                
                SwiftUIMarkdownRenderer(markdownText: content, readerSettings: readerSettings)
                    .padding(.top, 2) // Small gap between title and content
            }
            
            Spacer()
        }
        .padding(.horizontal, 20) // More horizontal padding
        .padding(.vertical, 16) // More vertical padding
        .background(effectiveColor.opacity(0.08)) // Slightly more subtle background
        .cornerRadius(16) // More rounded corners
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(effectiveColor.opacity(0.2), lineWidth: 1) // Lighter border
        )
        // Shadow removed for better performance
    }
}

enum CalloutType: String, CaseIterable {
    case note = "NOTE"
    case tip = "TIP"
    case important = "IMPORTANT"
    case warning = "WARNING"
    case caution = "CAUTION"
    case info = "INFO"
    case example = "EXAMPLE"
    case quote = "QUOTE"
    
    var color: Color {
        switch self {
        case .note: return .blue
        case .tip: return .green
        case .important: return .purple
        case .warning: return .orange
        case .caution: return .red
        case .info: return .cyan
        case .example: return .indigo
        case .quote: return .gray
        }
    }
    
    var icon: String {
        switch self {
        case .note: return "info.circle.fill"
        case .tip: return "lightbulb.fill"
        case .important: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .caution: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        case .example: return "doc.text.fill"
        case .quote: return "quote.bubble.fill"
        }
    }
}