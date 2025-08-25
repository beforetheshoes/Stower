import Testing
import Foundation
import SwiftUI
@testable import StowerFeature

@Suite("Reader Settings Persistence Tests", .serialized)
struct ReaderSettingsTests {
    
    @Test("Settings should save to UserDefaults when changed")
    func testSettingsSaveToUserDefaults() async throws {
        // Given: Isolated UserDefaults instance
        let defaults = UserDefaults.makeIsolated()
        let testKey = "testSettingsSaveToUserDefaults"
        
        // When: Creating ReaderSettings and changing values
        let settings = ReaderSettings.createForTesting(with: defaults, isolationKey: testKey)
        settings.selectedPreset = .custom  // Set to custom to allow direct custom property assignment
        settings.customFontSize = 20.0
        settings.customFont = .serif
        settings.isDarkMode = true
        
        // Then: Settings should be saved to UserDefaults automatically via didSet
        // Additional explicit save call for verification
        settings.save()
        
        let savedData = defaults.data(forKey: testKey)
        #expect(savedData != nil, "Settings data should be saved to UserDefaults")
    }
    
    @Test("Settings should load from UserDefaults on initialization") 
    func testSettingsLoadFromUserDefaults() async throws {
        // Given: Isolated UserDefaults instance
        let defaults = UserDefaults.makeIsolated()
        
        // Given: Settings saved in UserDefaults with custom preset
        let testKey = "testSettingsLoadFromUserDefaults"
        let originalSettings = ReaderSettings.createForTesting(with: defaults, isolationKey: testKey)
        originalSettings.selectedPreset = .custom  // Use custom to save custom values
        originalSettings.customFontSize = 22.0
        originalSettings.customFont = .monospaced
        originalSettings.customBackground = .sepia
        originalSettings.isDarkMode = false
        originalSettings.save()
        
        // When: Creating new ReaderSettings instance (simulating app restart)
        let newSettings = ReaderSettings.loadForTesting(from: defaults, isolationKey: testKey)
        
        // Then: Settings should match the saved values
        #expect(newSettings.selectedPreset == .custom)
        #expect(newSettings.customFont == .monospaced)
        #expect(newSettings.customBackground == .sepia)
        #expect(newSettings.isDarkMode == false)
    }
    
    @Test("Settings should use defaults when no saved data exists")
    func testSettingsUseDefaultsWhenNoSavedData() async throws {
        // Given: Clean UserDefaults with no saved settings (isolated instance is already clean)
        let defaults = UserDefaults.makeIsolated()
        
        // When: Loading settings
        let settings = ReaderSettings.load(from: defaults)
        
        // Then: Should use default values
        #expect(settings.selectedPreset == .default)
        #expect(settings.customFontSize == 16.0)
        #expect(settings.customFont == .system)
        #expect(settings.customBackground == .system)
        #expect(settings.isDarkMode == nil) // System preference
    }
    
    @Test("User presets should persist")
    func testUserPresetsPersistence() async throws {
        // Given: Isolated UserDefaults instance
        let defaults = UserDefaults.makeIsolated()
        
        // Given: Settings with user presets
        let settings = ReaderSettings.createForTesting(with: defaults, isolationKey: "testUserPresetsPersistence")
        settings.saveCurrentAsPreset(name: "My Custom Theme")
        settings.customAccentColor = .red
        settings.saveCurrentAsPreset(name: "Red Theme")
        
        // Ensure data is synchronously written before loading
        settings.save()
        defaults.synchronize()
        
        // When: Reloading (presets should already be saved by saveCurrentAsPreset)
        let reloadedSettings = ReaderSettings.loadForTesting(from: defaults, isolationKey: "testUserPresetsPersistence")
        
        // Then: User presets should be preserved
        #expect(reloadedSettings.userPresets.count == 2, "Expected 2 user presets, got \(reloadedSettings.userPresets.count)")
        #expect(reloadedSettings.userPresets.contains { $0.name == "My Custom Theme" }, "Missing 'My Custom Theme' preset")
        #expect(reloadedSettings.userPresets.contains { $0.name == "Red Theme" }, "Missing 'Red Theme' preset")
    }
    
    @Test("Settings should handle corrupted data gracefully")
    func testSettingsHandleCorruptedData() async throws {
        // Given: Isolated UserDefaults instance with corrupted data
        let defaults = UserDefaults.makeIsolated()
        defaults.set("invalid json data", forKey: "ReaderSettings")
        defaults.synchronize()
        
        // When: Loading settings
        let settings = ReaderSettings.load(from: defaults)
        
        // Then: Should fallback to defaults without crashing
        #expect(settings.selectedPreset == .default)
        #expect(settings.customFontSize == 16.0)
    }
    
    @Test("Color encoding and decoding should work correctly")
    func testColorCodable() async throws {
        // Given: A color value
        let originalColor = Color.blue
        
        // When: Encoding and decoding
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(originalColor)
        let decodedColor = try decoder.decode(Color.self, from: data)
        
        // Then: Colors should be equivalent (we'll need to implement proper hex conversion)
        // Note: This test will help us identify the Color.toHex() implementation issue
        #expect(decodedColor != Color.clear, "Decoded color should not be clear")
        #expect(data.count > 0, "Color should encode to some data")
    }
    
    @Test("Automatic saving should work with Observable changes")
    func testAutomaticSaving() async throws {
        // Given: Isolated UserDefaults instance
        let defaults = UserDefaults.makeIsolated()
        
        // Given: Settings that auto-save on changes
        let testKey = "testAutomaticSaving"
        let settings = ReaderSettings.createForTesting(with: defaults, isolationKey: testKey)
        
        // When: Changing a setting using convenience method
        settings.updatePreset(.highContrast)
        
        // Small delay to allow async saving
        try await Task.sleep(for: .milliseconds(100))
        
        // Then: Settings should be automatically saved
        let savedData = defaults.data(forKey: testKey)
        #expect(savedData != nil, "Settings should auto-save when changed")
        
        // Verify by loading fresh instance
        let reloadedSettings = ReaderSettings.loadForTesting(from: defaults, isolationKey: testKey)
        #expect(reloadedSettings.selectedPreset == .highContrast)
    }
    
    @Test("Custom preset with sepia background should use dark text")
    func testCustomPresetSepiaBackgroundTextColor() async throws {
        // Given: Custom preset with sepia background
        let settings = ReaderSettings()
        settings.selectedPreset = .custom
        settings.customBackground = .sepia
        settings.isDarkMode = true  // Dark mode enabled but should be overridden
        
        // When: Getting effective text color
        let textColor = settings.effectiveTextColor
        
        // Then: Should use dark text for readability on sepia background
        #expect(textColor == .black, "Sepia background should always use dark text for readability")
    }
    
    @Test("Custom preset with dark background should use light text")
    func testCustomPresetDarkBackgroundTextColor() async throws {
        // Given: Custom preset with dark background
        let settings = ReaderSettings()
        settings.selectedPreset = .custom
        settings.customBackground = .dark
        settings.isDarkMode = false  // Light mode enabled but should be overridden
        
        // When: Getting effective text color
        let textColor = settings.effectiveTextColor
        
        // Then: Should use light text for readability on dark background
        #expect(textColor == .white, "Dark background should always use light text for readability")
    }
    
    @Test("Custom preset with system background should respect color scheme")
    func testCustomPresetSystemBackgroundTextColor() async throws {
        // Given: Custom preset with system background and dark mode
        let settings = ReaderSettings()
        settings.selectedPreset = .custom
        settings.customBackground = .system
        settings.isDarkMode = true
        
        // When: Getting effective text color
        let textColor = settings.effectiveTextColor
        
        // Then: Should use light text for dark mode
        #expect(textColor == .white, "System background with dark mode should use light text")
        
        // And: Light mode should use dark text
        settings.isDarkMode = false
        let lightTextColor = settings.effectiveTextColor
        #expect(lightTextColor == .black, "System background with light mode should use dark text")
    }
}
