import SwiftUI

public struct ReaderSettingsView: View {
    @Binding var readerSettings: ReaderSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showingSavePresetDialog = false
    @State private var newPresetName = ""
    
    public init(readerSettings: Binding<ReaderSettings>) {
        self._readerSettings = readerSettings
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                presetSection
                
                if !readerSettings.userPresets.isEmpty {
                    userPresetsSection
                }
                
                if readerSettings.selectedPreset == .custom {
                    customizationSection
                    savePresetSection
                }
                
                previewSection
            }
            .navigationTitle("Reader Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
                #elseif os(macOS)
                ToolbarItem(placement: .automatic) {
                    Button("Done") {
                        dismiss()
                    }
                }
                #endif
            }
            .alert("Save Preset", isPresented: $showingSavePresetDialog) {
                TextField("Preset Name", text: $newPresetName)
                Button("Save") {
                    if !newPresetName.isEmpty {
                        readerSettings.saveCurrentAsPreset(name: newPresetName)
                        newPresetName = ""
                    }
                }
                Button("Cancel", role: .cancel) {
                    newPresetName = ""
                }
            } message: {
                Text("Enter a name for your custom preset")
            }
        }
    }
    
    @ViewBuilder
    private var presetSection: some View {
        Section("Presets") {
            ForEach(ReaderPreset.allCases, id: \.self) { preset in
                PresetRowView(
                    preset: preset,
                    isSelected: readerSettings.selectedPreset == preset
                ) {
                    readerSettings.selectedPreset = preset
                }
            }
        }
    }
    
    @ViewBuilder
    private var userPresetsSection: some View {
        Section("Your Presets") {
            ForEach(readerSettings.userPresets) { preset in
                UserPresetRowView(
                    preset: preset,
                    isSelected: false
                ) {
                    readerSettings.loadUserPreset(preset)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    readerSettings.deleteUserPreset(at: index)
                }
            }
        }
    }
    
    @ViewBuilder
    private var customizationSection: some View {
        Section("Customization") {
            // Accent Color
            HStack {
                Label("Accent Color", systemImage: "paintpalette.fill")
                Spacer()
                ColorPicker("", selection: $readerSettings.customAccentColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 40, height: 30)
            }
            
            // Font
            HStack {
                Label("Font", systemImage: "textformat")
                Spacer()
                Picker("Font", selection: $readerSettings.customFont) {
                    ForEach(ReaderFont.allCases, id: \.self) { font in
                        Text(font.displayName).tag(font)
                    }
                }
                .pickerStyle(.menu)
            }
            
            // Font Size
            VStack(alignment: .leading, spacing: 8) {
                Label("Font Size", systemImage: "textformat.size")
                HStack {
                    Text("A")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $readerSettings.customFontSize,
                        in: 12...24,
                        step: 1
                    )
                    Text("A")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                Text("\(Int(readerSettings.customFontSize))pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Background Style
            HStack {
                Label("Background", systemImage: "rectangle.fill")
                Spacer()
                Picker("Background", selection: $readerSettings.customBackground) {
                    ForEach(BackgroundStyle.allCases, id: \.self) { background in
                        HStack {
                            Text(background.displayName)
                            Spacer()
                            Circle()
                                .fill(background.color)
                                .frame(width: 12, height: 12)
                        }
                        .tag(background)
                    }
                }
                .pickerStyle(.menu)
            }
            
            // Dark Mode Override
            HStack {
                Label("Appearance", systemImage: "moon.fill")
                Spacer()
                Picker("Appearance", selection: $readerSettings.isDarkMode) {
                    Text("System").tag(nil as Bool?)
                    Text("Light").tag(false as Bool?)
                    Text("Dark").tag(true as Bool?)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
        }
    }
    
    @ViewBuilder
    private var savePresetSection: some View {
        Section("Save Preset") {
            Button {
                showingSavePresetDialog = true
            } label: {
                Label("Save Current Settings", systemImage: "plus.circle.fill")
            }
        }
    }
    
    @ViewBuilder
    private var previewSection: some View {
        Section("Preview") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(readerSettings.effectiveAccentColor)
                    Text("Sample Article")
                        .font(.system(size: readerSettings.effectiveFontSize, design: readerSettings.effectiveFont.fontDesign))
                        .fontWeight(.medium)
                }
                
                Text("This is how your articles will appear with the current settings. The font, size, and colors will be applied throughout the reader interface.")
                    .font(.system(size: readerSettings.effectiveFontSize - 1, design: readerSettings.effectiveFont.fontDesign))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(readerSettings.effectiveAccentColor)
                        .frame(width: 3, height: 40)
                    
                    Text("Sample blockquote text showing how quoted content will appear.")
                        .font(.system(size: readerSettings.effectiveFontSize - 2, design: readerSettings.effectiveFont.fontDesign))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

private struct PresetRowView: View {
    let preset: ReaderPreset
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.rawValue)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Text(preset.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    // Color indicator
                    Circle()
                        .fill(preset.accentColor)
                        .frame(width: 12, height: 12)
                    
                    // Font indicator
                    Text("Aa")
                        .font(.system(size: 12, design: preset.font.fontDesign))
                        .foregroundStyle(.secondary)
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(preset.accentColor)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct UserPresetRowView: View {
    let preset: UserPreset
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    HStack(spacing: 8) {
                        // Background indicator
                        Circle()
                            .fill(preset.background.color)
                            .frame(width: 12, height: 12)
                        
                        // Accent color indicator
                        Circle()
                            .fill(preset.accentColor)
                            .frame(width: 12, height: 12)
                        
                        // Font indicator
                        Text("Aa")
                            .font(.system(size: 12, design: preset.font.fontDesign))
                            .foregroundStyle(.secondary)
                        
                        // Size indicator
                        Text("\(Int(preset.fontSize))pt")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text(preset.dateCreated, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(preset.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ReaderSettingsSheet: View {
    @Environment(ReaderSettings.self) private var readerSettings
    
    var body: some View {
        ReaderSettingsView(readerSettings: Binding(
            get: { readerSettings },
            set: { newSettings in
                // Update the environment object's properties
                readerSettings.selectedPreset = newSettings.selectedPreset
                readerSettings.customAccentColor = newSettings.customAccentColor
                readerSettings.customFont = newSettings.customFont
                readerSettings.customFontSize = newSettings.customFontSize
                readerSettings.customBackground = newSettings.customBackground
                readerSettings.isDarkMode = newSettings.isDarkMode
            }
        ))
    }
}

#Preview("Reader Settings") {
    @Previewable @State var settings = ReaderSettings()
    
    ReaderSettingsView(readerSettings: $settings)
}