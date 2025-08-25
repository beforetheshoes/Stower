import Testing
import SwiftUI
@testable import StowerFeature

@Suite("Preset Customization Flow Tests")
struct PresetCustomizationTests {
    
    @Test("transitionToCustomMode preserves all preset values")
    func transitionToCustomModePreservesValues() async throws {
        let settings = ReaderSettings()
        
        // Start with Sepia preset
        settings.selectedPreset = .sepia
        
        // Verify we're not in custom mode yet
        #expect(settings.selectedPreset == .sepia)
        
        // Get the effective values before transition
        let originalAccent = settings.effectiveAccentColor
        let originalFont = settings.effectiveFont
        let originalFontSize = settings.effectiveFontSize
        let originalBackground = settings.selectedPreset == .custom ? settings.customBackground : settings.mapPresetToBackgroundStyle(.sepia)
        let originalColorScheme = settings.selectedPreset.colorScheme
        
        // Transition to custom mode
        settings.transitionToCustomMode()
        
        // Verify we're now in custom mode
        #expect(settings.selectedPreset == .custom)
        
        // Verify all values were preserved
        #expect(settings.customAccentColor == originalAccent)
        #expect(settings.customFont == originalFont)
        #expect(settings.customFontSize == originalFontSize)
        #expect(settings.customBackground == originalBackground)
        #expect(settings.isDarkMode == (originalColorScheme == .dark ? true : originalColorScheme == .light ? false : nil))
        
        // Verify effective values are still the same
        #expect(settings.effectiveAccentColor == originalAccent)
        #expect(settings.effectiveFont == originalFont)
        #expect(settings.effectiveFontSize == originalFontSize)
    }
    
    @Test("transitionToCustomMode is idempotent when already custom")
    func transitionToCustomModeIdempotent() async throws {
        let settings = ReaderSettings()
        
        // Start in custom mode with specific values
        settings.selectedPreset = .custom
        settings.customAccentColor = .red
        settings.customFont = .serif
        settings.customFontSize = 20
        settings.customBackground = .dark
        settings.isDarkMode = true
        
        // Store original values
        let originalAccent = settings.customAccentColor
        let originalFont = settings.customFont
        let originalFontSize = settings.customFontSize
        let originalBackground = settings.customBackground
        let originalDarkMode = settings.isDarkMode
        
        // Transition should be no-op
        settings.transitionToCustomMode()
        
        // Verify nothing changed
        #expect(settings.selectedPreset == .custom)
        #expect(settings.customAccentColor == originalAccent)
        #expect(settings.customFont == originalFont)
        #expect(settings.customFontSize == originalFontSize)
        #expect(settings.customBackground == originalBackground)
        #expect(settings.isDarkMode == originalDarkMode)
    }
    
    @Test("All presets transition correctly to custom mode")
    func allPresetsTransitionCorrectly() async throws {
        let settings = ReaderSettings()
        
        // Test each preset
        for preset in ReaderPreset.allCases where preset != .custom {
            settings.selectedPreset = preset
            
            // Get expected values
            let expectedAccent = preset.accentColor
            let expectedFont = preset.font
            let expectedFontSize = preset.fontSize
            let expectedBackground = settings.mapPresetToBackgroundStyle(preset)
            let expectedColorScheme = preset.colorScheme
            
            // Transition to custom
            settings.transitionToCustomMode()
            
            // Verify transition
            #expect(settings.selectedPreset == .custom)
            #expect(settings.customAccentColor == expectedAccent)
            #expect(settings.customFont == expectedFont)
            #expect(settings.customFontSize == expectedFontSize)
            #expect(settings.customBackground == expectedBackground)
            
            let expectedDarkMode = expectedColorScheme == .dark ? true : expectedColorScheme == .light ? false : nil
            #expect(settings.isDarkMode == expectedDarkMode)
        }
    }
    
    @Test("Preset mapping to BackgroundStyle works correctly")
    func presetBackgroundStyleMapping() async throws {
        let settings = ReaderSettings()
        
        // Test the mapping function
        #expect(settings.mapPresetToBackgroundStyle(.sepia) == .sepia)
        #expect(settings.mapPresetToBackgroundStyle(.academic) == .paper)
        #expect(settings.mapPresetToBackgroundStyle(.darkMode) == .dark)
        #expect(settings.mapPresetToBackgroundStyle(.highContrast) == .paper)
        #expect(settings.mapPresetToBackgroundStyle(.default) == .system)
        #expect(settings.mapPresetToBackgroundStyle(.minimal) == .system)
    }
    
    @Test("Sequential preset changes preserve values correctly")
    func sequentialPresetChanges() async throws {
        let settings = ReaderSettings()
        
        // Start with Academic
        settings.selectedPreset = .academic
        #expect(settings.effectiveFont == .serif)
        #expect(settings.effectiveFontSize == 17)
        
        // Transition to custom (should preserve Academic values)
        settings.transitionToCustomMode()
        #expect(settings.selectedPreset == .custom)
        #expect(settings.customFont == .serif)
        #expect(settings.customFontSize == 17)
        
        // Change to Minimal preset
        settings.selectedPreset = .minimal
        #expect(settings.effectiveFont == .rounded)
        #expect(settings.effectiveFontSize == 15)
        
        // Transition again (should preserve Minimal values, not Academic)
        settings.transitionToCustomMode()
        #expect(settings.selectedPreset == .custom)
        #expect(settings.customFont == .rounded)
        #expect(settings.customFontSize == 15)
    }
    
    @Test("transitionToCustomMode triggers save when auto-save enabled")
    func transitionTriggersAutoSave() async throws {
        let testDefaults = UserDefaults(suiteName: "PresetCustomizationTest")!
        let testKey = "testTransitionAutoSave"
        testDefaults.removeObject(forKey: testKey)
        
        let settings = ReaderSettings.loadForTesting(from: testDefaults, isolationKey: testKey)
        
        // Start with a preset
        settings.selectedPreset = .sepia
        
        // Clear any existing data to ensure clean test
        testDefaults.removeObject(forKey: testKey)
        
        // Transition should trigger auto-save
        settings.transitionToCustomMode()
        
        // Verify data was saved
        let savedData = testDefaults.data(forKey: testKey)
        #expect(savedData != nil)
        
        // Verify we can reload and get the custom mode with preserved values
        let reloadedSettings = ReaderSettings.loadForTesting(from: testDefaults, isolationKey: testKey)
        #expect(reloadedSettings.selectedPreset == .custom)
        #expect(reloadedSettings.customAccentColor == Color.brown) // Sepia's accent color
        #expect(reloadedSettings.customFont == .serif) // Sepia's font
    }
    
    @Test("Customizing Sepia preset accent color preserves all Sepia values")
    func customizeSepiaPresentAccentColor() async throws {
        let settings = ReaderSettings()
        
        // Start with Sepia preset (the user's scenario)
        settings.selectedPreset = .sepia
        
        // Verify initial Sepia values
        #expect(settings.effectiveAccentColor == Color.brown)
        #expect(settings.effectiveFont == .serif)
        #expect(settings.effectiveFontSize == 17)
        
        // Simulate user clicking accent color picker and changing to blue
        // This is what the ColorPicker binding does now
        settings.transitionToCustomMode()
        settings.customAccentColor = .blue
        settings.saveIfNeeded()
        
        // Verify we're now in custom mode with blue accent but all other Sepia values preserved
        #expect(settings.selectedPreset == .custom)
        #expect(settings.customAccentColor == .blue) // Changed
        #expect(settings.customFont == .serif) // Preserved from Sepia
        #expect(settings.customFontSize == 17) // Preserved from Sepia
        #expect(settings.customBackground == .sepia) // Preserved from Sepia
        
        // Verify effective values reflect the mix
        #expect(settings.effectiveAccentColor == .blue)
        #expect(settings.effectiveFont == .serif)
        #expect(settings.effectiveFontSize == 17)
    }
    
    @Test("Customizing Academic preset font preserves all Academic values")
    func customizeAcademicPresentFont() async throws {
        let settings = ReaderSettings()
        
        // Start with Academic preset
        settings.selectedPreset = .academic
        
        // Verify initial Academic values
        #expect(settings.effectiveAccentColor == Color.indigo)
        #expect(settings.effectiveFont == .serif)
        #expect(settings.effectiveFontSize == 17)
        
        // Simulate user changing font to rounded
        settings.transitionToCustomMode()
        settings.customFont = .rounded
        settings.saveIfNeeded()
        
        // Verify preserved values with font change
        #expect(settings.selectedPreset == .custom)
        #expect(settings.customAccentColor == Color.indigo) // Preserved from Academic
        #expect(settings.customFont == .rounded) // Changed
        #expect(settings.customFontSize == 17) // Preserved from Academic
        #expect(settings.customBackground == .paper) // Preserved from Academic
    }
    
    @Test("Multiple sequential customizations work correctly")
    func multipleSequentialCustomizations() async throws {
        let settings = ReaderSettings()
        
        // Start with Dark Mode preset
        settings.selectedPreset = .darkMode
        
        // First customization: change accent color
        settings.transitionToCustomMode()
        settings.customAccentColor = .red
        
        // Verify we're in custom mode with Dark Mode base + red accent
        #expect(settings.selectedPreset == .custom)
        #expect(settings.customAccentColor == .red)
        #expect(settings.customFont == .system) // From Dark Mode
        #expect(settings.customFontSize == 16) // From Dark Mode
        
        // Second customization: change font size (already in custom mode)
        settings.transitionToCustomMode() // Should be no-op
        settings.customFontSize = 20
        
        // Verify both changes preserved
        #expect(settings.customAccentColor == .red) // Still red
        #expect(settings.customFont == .system) // Still from Dark Mode
        #expect(settings.customFontSize == 20) // Changed
    }
    
    @Test("Edge case: rapid preset switching then customization")
    func rapidPresetSwitchingThenCustomization() async throws {
        let settings = ReaderSettings()
        
        // Rapidly switch between presets (user exploring)
        settings.selectedPreset = .sepia
        settings.selectedPreset = .academic  
        settings.selectedPreset = .minimal
        settings.selectedPreset = .highContrast
        
        // Now customize - should use High Contrast as base
        settings.transitionToCustomMode()
        settings.customAccentColor = .green
        
        // Verify High Contrast values were preserved (not previous presets)
        #expect(settings.selectedPreset == .custom)
        #expect(settings.customAccentColor == .green) // Changed
        #expect(settings.customFont == .system) // From High Contrast
        #expect(settings.customFontSize == 18) // From High Contrast  
        #expect(settings.customBackground == .paper) // From High Contrast
    }
}