import Testing
import Foundation
import SwiftUI
@testable import StowerFeature

@Suite("Color Scheme Application Tests")
struct ColorSchemeTests {
    
    @Test("ReaderSettings effectiveColorScheme returns correct values")
    func testEffectiveColorScheme() async throws {
        // Test default preset (should be nil/system)
        let defaultSettings = ReaderSettings()
        defaultSettings.selectedPreset = .default
        #expect(defaultSettings.effectiveColorScheme == nil)
        
        // Test dark mode preset
        let darkSettings = ReaderSettings()
        darkSettings.selectedPreset = .darkMode
        #expect(darkSettings.effectiveColorScheme == .dark)
        
        // Test custom with explicit dark mode
        let customDarkSettings = ReaderSettings()
        customDarkSettings.selectedPreset = .custom
        customDarkSettings.isDarkMode = true
        #expect(customDarkSettings.effectiveColorScheme == .dark)
        
        // Test custom with explicit light mode
        let customLightSettings = ReaderSettings()
        customLightSettings.selectedPreset = .custom
        customLightSettings.isDarkMode = false
        #expect(customLightSettings.effectiveColorScheme == .light)
        
        // Test custom with system preference (nil)
        let customSystemSettings = ReaderSettings()
        customSystemSettings.selectedPreset = .custom
        customSystemSettings.isDarkMode = nil
        #expect(customSystemSettings.effectiveColorScheme == nil)
        
        print("✅ Color scheme tests passed - all modes work correctly")
    }
}