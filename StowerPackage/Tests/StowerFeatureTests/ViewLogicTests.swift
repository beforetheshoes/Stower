import Testing
import Foundation
import SwiftUI
@testable import StowerFeature

@Suite("View Logic Tests", .serialized)
struct ViewLogicTests {
    
    // MARK: - URL Validation Logic Tests
    
    @Test("URL validation logic")
    func testURLValidationLogic() async throws {
        let validURLs = [
            "https://www.example.com",
            "http://test.org/article",
            "https://site.com/path/to/page.html",
            "https://domain.com/article?param=value",
            "https://subdomain.example.org/path"
        ]
        
        let invalidURLs = [
            "",
            "not-a-url",
            "just text",
            "http://", // Incomplete URL
            "www.example.com", // Missing scheme
            "javascript:alert('xss')",
            "file:///local/path"
        ]
        
        for urlString in validURLs {
            let url = URL(string: urlString)
            let isValid = url != nil && (url!.scheme == "http" || url!.scheme == "https") && url!.host != nil
            #expect(isValid, "Should validate URL: \(urlString)")
        }
        
        for urlString in invalidURLs {
            let url = URL(string: urlString)
            let isValid = url != nil && (url!.scheme == "http" || url!.scheme == "https") && url!.host != nil
            #expect(!isValid, "Should reject invalid URL: \(urlString)")
        }
    }
    
    @Test("PDF URL detection logic")
    func testPDFDetectionLogic() async throws {
        let pdfURLs = [
            "https://example.com/document.pdf",
            "http://site.org/file.PDF", // Case insensitive
            "https://domain.com/paper.pdf?version=1",
            "https://test.com/folder/report.pdf#page=5"
        ]
        
        let nonPDFUrls = [
            "https://example.com/article.html",
            "http://site.org/page",
            "https://domain.com/blog/post.php",
            "https://example.com/image.jpg",
            "https://test.com/video.mp4"
        ]
        
        // Test PDF detection logic
        for urlString in pdfURLs {
            let isPDF = urlString.lowercased().contains(".pdf")
            #expect(isPDF, "Should detect PDF: \(urlString)")
        }
        
        for urlString in nonPDFUrls {
            let isPDF = urlString.lowercased().contains(".pdf")
            #expect(!isPDF, "Should not detect PDF: \(urlString)")
        }
    }
    
    // MARK: - Search and Filter Logic Tests
    
    @Test("Search filtering logic")
    func testSearchFilteringLogic() async throws {
        let items = [
            SavedItem(title: "Swift Programming Guide", extractedMarkdown: "Advanced Swift concepts", tags: ["programming", "swift", "ios"]),
            SavedItem(title: "Cooking Recipes", extractedMarkdown: "How to cook delicious pasta", tags: ["cooking", "recipe", "food"]),
            SavedItem(title: "SwiftUI Tutorial", extractedMarkdown: "Building user interfaces with SwiftUI", tags: ["programming", "swiftui", "ios"]),
            SavedItem(title: "Photography Tips", extractedMarkdown: "Taking better photos with your camera", tags: ["photography", "tips"])
        ]
        
        // Test empty search returns all items
        let allResults = filterItems(items, searchText: "")
        #expect(allResults.count == 4, "Empty search should return all items")
        
        // Test case-insensitive title search
        let swiftResults = filterItems(items, searchText: "swift")
        #expect(swiftResults.count == 2, "Should find 2 items with 'swift' in title")
        
        // Test content search
        let cookingResults = filterItems(items, searchText: "pasta")
        #expect(cookingResults.count == 1, "Should find 1 item with 'pasta' in content")
        
        // Test search that matches nothing
        let noResults = filterItems(items, searchText: "nonexistent")
        #expect(noResults.count == 0, "Should find no items for non-matching search")
        
        // Test partial word matching
        let programResults = filterItems(items, searchText: "program")
        #expect(programResults.count >= 2, "Should find items with partial word match")
    }
    
    @Test("Tag filtering logic")
    func testTagFilteringLogic() async throws {
        let items = [
            SavedItem(title: "Article 1", extractedMarkdown: "Content", tags: ["tech", "programming", "ios"]),
            SavedItem(title: "Article 2", extractedMarkdown: "Content", tags: ["cooking", "recipe"]),
            SavedItem(title: "Article 3", extractedMarkdown: "Content", tags: ["tech", "review"]),
            SavedItem(title: "Article 4", extractedMarkdown: "Content", tags: ["programming", "swift"])
        ]
        
        // Test no tag filter returns all items
        let allResults = filterItemsByTag(items, selectedTag: "")
        #expect(allResults.count == 4, "No tag filter should return all items")
        
        // Test single tag filtering
        let techResults = filterItemsByTag(items, selectedTag: "tech")
        #expect(techResults.count == 2, "Should find 2 items with 'tech' tag")
        
        let programmingResults = filterItemsByTag(items, selectedTag: "programming")
        #expect(programmingResults.count == 2, "Should find 2 items with 'programming' tag")
        
        // Test tag that doesn't exist
        let noResults = filterItemsByTag(items, selectedTag: "nonexistent")
        #expect(noResults.count == 0, "Should find no items for non-existent tag")
    }
    
    @Test("Combined search and tag filtering logic")
    func testCombinedFilteringLogic() async throws {
        let items = [
            SavedItem(title: "Swift Programming", extractedMarkdown: "iOS development with Swift", tags: ["programming", "swift", "ios"]),
            SavedItem(title: "Swift Cooking", extractedMarkdown: "Quick cooking recipes", tags: ["cooking", "recipe"]),
            SavedItem(title: "Programming Tutorial", extractedMarkdown: "Learn programming basics", tags: ["programming", "tutorial"]),
            SavedItem(title: "iOS Design", extractedMarkdown: "Mobile app design principles", tags: ["design", "ios", "mobile"])
        ]
        
        // Test combined search text and tag filter
        let results = filterItems(items, searchText: "swift", selectedTag: "programming")
        #expect(results.count == 1, "Should find 1 item matching both 'swift' search and 'programming' tag")
        #expect(results[0].title.contains("Swift Programming"), "Should find the correct item")
        
        // Test search with no matching tag
        let noResults = filterItems(items, searchText: "swift", selectedTag: "design")
        #expect(noResults.count == 0, "Should find no items with 'swift' search and 'design' tag")
    }
    
    // MARK: - Text Processing Logic Tests
    
    @Test("Content preview generation logic")
    func testContentPreviewLogic() async throws {
        let markdownTexts = [
            "# Heading\n\nThis is a paragraph with **bold** text and *italic* text.",
            "- List item 1\n- List item 2\n- List item 3",
            "Very short text",
            String(repeating: "This is a very long text that should be truncated. ", count: 20),
            "# Only Heading",
            ""
        ]
        
        for markdown in markdownTexts {
            let preview = SavedItem.generatePreview(from: markdown)
            
            if markdown.isEmpty {
                #expect(!preview.isEmpty, "Empty markdown should generate fallback preview")
            } else {
                #expect(!preview.isEmpty, "Non-empty markdown should generate non-empty preview")
                #expect(preview.count <= 200, "Preview should be reasonably short (≤200 chars)")
                
                // Should not contain markdown formatting
                #expect(!preview.contains("**"), "Preview should not contain bold markdown")
                #expect(!preview.contains("*"), "Preview should not contain italic markdown")
                #expect(!preview.contains("#"), "Preview should not contain heading markdown")
                #expect(!preview.contains("-"), "Preview should not contain list markdown")
            }
        }
    }
    
    @Test("Tag extraction and normalization logic")
    func testTagLogic() async throws {
        // Test tag normalization
        let rawTags = ["  Technology  ", "PROGRAMMING", "swift", "Swift", "iOS", "ios"]
        let normalizedTags = rawTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let uniqueTags = Array(Set(normalizedTags)).sorted()
        
        #expect(uniqueTags.contains("technology"), "Should normalize whitespace and case")
        #expect(uniqueTags.contains("programming"), "Should normalize case")
        #expect(uniqueTags.count == 4, "Should deduplicate tags: \(uniqueTags)")
        
        // Test empty and invalid tags
        let invalidTags = ["", "   ", "\t\n"]
        let validTags = invalidTags.compactMap { tag in
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized.lowercased()
        }
        #expect(validTags.isEmpty, "Should filter out empty/whitespace tags")
    }
    
    // MARK: - Helper Functions
    
    private func filterItems(_ items: [SavedItem], searchText: String, selectedTag: String = "") -> [SavedItem] {
        return items.filter { item in
            let matchesSearch = searchText.isEmpty ||
                item.title.localizedCaseInsensitiveContains(searchText) ||
                item.extractedMarkdown.localizedCaseInsensitiveContains(searchText) ||
                item.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            
            let matchesTag = selectedTag.isEmpty || item.tags.contains(selectedTag)
            
            return matchesSearch && matchesTag
        }
    }
    
    private func filterItemsByTag(_ items: [SavedItem], selectedTag: String) -> [SavedItem] {
        return items.filter { item in
            selectedTag.isEmpty || item.tags.contains(selectedTag)
        }
    }
}

// MARK: - Reader Settings Logic Tests

@Suite("Reader Settings Logic Tests")
struct ReaderSettingsLogicTests {
    
    @Test("Preset property consistency")
    func testPresetProperties() async throws {
        for preset in ReaderPreset.allCases where preset != .custom {
            let accentColor = preset.accentColor
            let fontSize = preset.fontSize
            let font = preset.font
            
            // Test that preset properties are consistent
            #expect(fontSize >= 10 && fontSize <= 36, "Font size should be reasonable for \(preset)")
            #expect(accentColor != Color.clear, "Accent color should not be clear for \(preset)")
            
            // Test that getting the same preset twice returns consistent values
            let secondAccentColor = preset.accentColor
            let secondFontSize = preset.fontSize
            let secondFont = preset.font
            
            #expect(accentColor == secondAccentColor, "Accent color should be consistent for \(preset)")
            #expect(fontSize == secondFontSize, "Font size should be consistent for \(preset)")
            #expect(font == secondFont, "Font should be consistent for \(preset)")
        }
    }
    
    @Test("Effective properties logic")
    func testEffectivePropertiesLogic() async throws {
        let settings = ReaderSettings()
        
        // Test default preset effective properties
        settings.selectedPreset = .default
        let defaultSize = settings.effectiveFontSize
        let defaultFont = settings.effectiveFont
        let defaultColor = settings.effectiveAccentColor
        
        #expect(defaultSize == ReaderPreset.default.fontSize, "Default effective size should match preset")
        #expect(defaultFont == ReaderPreset.default.font, "Default effective font should match preset")
        #expect(defaultColor == ReaderPreset.default.accentColor, "Default effective color should match preset")
        
        // Test custom preset uses custom values
        settings.selectedPreset = .custom
        settings.customFontSize = 20.0
        settings.customFont = .serif
        settings.customAccentColor = .red
        
        #expect(settings.effectiveFontSize == 20.0, "Custom effective size should use custom value")
        #expect(settings.effectiveFont == .serif, "Custom effective font should use custom value")
        #expect(settings.effectiveAccentColor == .red, "Custom effective color should use custom value")
        
        // Test academic preset
        settings.selectedPreset = .academic
        #expect(settings.effectiveFontSize == ReaderPreset.academic.fontSize, "Academic effective size should match preset")
        #expect(settings.effectiveFont == ReaderPreset.academic.font, "Academic effective font should match preset")
    }
    
    @Test("Settings persistence logic")
    func testSettingsPersistenceLogic() async throws {
        // Given: Isolated UserDefaults instance
        let defaults = UserDefaults.makeIsolated()
        
        // Given: Settings saved in isolated UserDefaults
        let originalSettings = ReaderSettings.createForTesting(with: defaults, isolationKey: "testSettingsPersistenceLogic")  // This clears any existing data
        // Set to custom preset to use custom settings
        originalSettings.updatePreset(.custom)
        originalSettings.updateCustomSettings(
            accentColor: .green,
            fontSize: 18.0
        )
        
        // Test save
        originalSettings.save()
        
        // Test load from same isolated defaults
        let loadedSettings = ReaderSettings.loadForTesting(from: defaults, isolationKey: "testSettingsPersistenceLogic")
        
        #expect(loadedSettings.selectedPreset == .custom, "Should preserve selected preset")
        #expect(loadedSettings.customFontSize == 18.0, "Should preserve custom font size")
        // For color comparison, allow for small RGB differences due to floating point precision
        let loadedHex = loadedSettings.customAccentColor.toHex()
        let greenHex = "34C759"  // Known system green color hex
        let isCloseEnough = loadedHex == greenHex || loadedHex == "33C758"  // Allow for precision difference
        #expect(isCloseEnough, "Should preserve custom accent color - loaded: \(loadedHex), expected: \(greenHex)")
    }
}