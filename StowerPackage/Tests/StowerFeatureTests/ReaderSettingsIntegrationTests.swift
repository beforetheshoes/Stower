import Testing
import Foundation
import SwiftUI
@testable import StowerFeature

@Suite("Reader Settings Integration Tests", .serialized)
struct ReaderSettingsIntegrationTests {
    
    @Test("ContentView loads settings from UserDefaults on app launch")
    @MainActor
    func testContentViewLoadsSettingsFromUserDefaults() async throws {
        // Given: Isolated UserDefaults instance
        let defaults = UserDefaults.makeIsolated()
        
        // Use testing override for this integration test
        TestDefaultsScope.use(defaults) {
            let testSettings = ReaderSettings()  // Will use override
            testSettings.updatePreset(.academic)  // Academic is a preset, should work as-is
            
            // Ensure the save operation completes by explicitly calling save
            testSettings.save()
            
            // When: ContentView creates ReaderSettings using loadFromUserDefaults
            let loadedSettings = ReaderSettings.loadFromUserDefaults()  // Will use override
            
            // Then: Settings should match what was saved
            #expect(loadedSettings.selectedPreset == .academic)
            // For preset-based settings, font size and font come from the preset
            #expect(loadedSettings.effectiveFontSize == 17.0)  // Academic preset font size
            #expect(loadedSettings.effectiveFont == .serif)    // Academic preset font
            
            print("✅ Integration test passed - ContentView properly loads saved settings")
        }
    }
    
    @Test("Settings automatically enable auto-save when loaded from UserDefaults")
    @MainActor
    func testAutoSaveEnabledByDefault() async throws {
        // Given: Isolated UserDefaults instance
        let defaults = UserDefaults.makeIsolated()
        
        // Use testing override for this integration test
        TestDefaultsScope.use(defaults) {
            // When: Loading settings (as ContentView does)
            let settings = ReaderSettings.loadFromUserDefaults()  // Will use override
            
            // Then: Auto-save should be enabled and settings should persist
            settings.updatePreset(.sepia)  // Use a preset to test preset persistence
            
            // Verify persistence
            let reloadedSettings = ReaderSettings.loadFromUserDefaults()  // Will use override
            #expect(reloadedSettings.selectedPreset == .sepia)
            #expect(reloadedSettings.effectiveFontSize == 17.0)  // Sepia preset font size
            
            print("✅ Integration test passed - auto-save enabled by default")
        }
    }
}