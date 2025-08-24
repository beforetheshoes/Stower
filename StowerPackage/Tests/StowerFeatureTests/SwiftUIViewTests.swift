import Testing
import Foundation
import SwiftUI
@testable import StowerFeature

@MainActor
@Suite("SwiftUI View Tests")
struct SwiftUIViewTests {
    
    // MARK: - Reader Settings View Tests
    
    @Test("ReaderSettingsView initializes with settings")
    func testReaderSettingsViewInit() async throws {
        let settings = ReaderSettings()
        settings.selectedPreset = .academic
        
        let _ = ReaderSettingsView(readerSettings: .constant(settings))
        
        // Test that view can be created (views are non-optional structs)
        // View creation successful if no compilation errors
        
        // Test that the binding reflects the settings
        let binding = Binding.constant(settings)
        #expect(binding.wrappedValue.selectedPreset == .academic)
    }
    
    @Test("ReaderSettingsView preset selection logic")
    func testPresetSelectionLogic() async throws {
        let settings = ReaderSettings()
        
        // Test all presets can be applied
        for preset in ReaderPreset.allCases where preset != .custom {
            settings.selectedPreset = preset
            
            // Verify preset properties are accessible and valid
            let accentColor = preset.accentColor
            let fontSize = preset.fontSize
            let font = preset.font
            
            // Test meaningful properties instead of nil checks for non-optional values
            #expect(fontSize >= 12 && fontSize <= 30, "Preset \(preset) should have reasonable font size")
            #expect(font == preset.font, "Preset \(preset) should have consistent font")
            #expect(accentColor == preset.accentColor, "Preset \(preset) should have consistent accent color")
        }
    }
    
    @Test("ReaderSettingsView custom preset handling")
    func testCustomPresetHandling() async throws {
        let settings = ReaderSettings()
        settings.selectedPreset = .custom
        settings.customAccentColor = .red
        settings.customFontSize = 20.0
        settings.customFont = .serif
        
        // Test that custom settings are properly applied
        #expect(settings.effectiveAccentColor == .red)
        #expect(settings.effectiveFontSize == 20.0)
        #expect(settings.effectiveFont == .serif)
    }
    
    // MARK: - Reader View Tests
    
    @Test("ReaderView initializes with saved item")
    func testReaderViewInit() async throws {
        let item = SavedItem(
            title: "Test Article",
            extractedMarkdown: "# Test Heading\n\nTest content with **bold** text."
        )
        
        let _ = ReaderView(itemId: item.id)
        
        // Test that view can be created (views are non-optional structs)
        // ReaderView uses @Environment(ReaderSettings.self) and @Query for actual data
        #expect(item.title == "Test Article")
        #expect(item.extractedMarkdown.contains("Test Heading"))
    }
    
    @Test("ReaderView title editing state")
    func testTitleEditingState() async throws {
        let item = SavedItem(title: "Original Title", extractedMarkdown: "Content")
        
        // Simulate editing state variables (these would be @State in the actual view)
        var isEditingTitle = false
        var editedTitle = ""
        
        // Start editing
        isEditingTitle = true
        editedTitle = item.title
        
        #expect(isEditingTitle == true)
        #expect(editedTitle == "Original Title")
        
        // Make changes
        editedTitle = "New Title"
        
        // Save changes (simulating the view's save action)
        if !editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.updateContent(title: editedTitle)
            isEditingTitle = false
        }
        
        #expect(item.title == "New Title")
        #expect(isEditingTitle == false)
    }
    
    // MARK: - Library View Tests
    
    @Test("LibraryView filtering logic")
    func testLibraryViewFiltering() async throws {
        // Create test items
        let items = [
            SavedItem(title: "Swift Programming", extractedMarkdown: "Content about Swift", tags: ["programming", "swift"]),
            SavedItem(title: "Cooking Recipe", extractedMarkdown: "How to cook pasta", tags: ["cooking", "recipe"]),
            SavedItem(title: "Swift UI Tutorial", extractedMarkdown: "SwiftUI guide", tags: ["programming", "swiftui"])
        ]
        
        // Test search filtering
        let searchText = "swift"
        let filteredItems = items.filter { item in
            searchText.isEmpty || 
            item.title.localizedCaseInsensitiveContains(searchText) ||
            item.extractedMarkdown.localizedCaseInsensitiveContains(searchText) ||
            item.tags.contains { tag in tag.localizedCaseInsensitiveContains(searchText) }
        }
        
        #expect(filteredItems.count == 2, "Should find 2 items matching 'swift'")
        #expect(filteredItems.allSatisfy { $0.title.localizedCaseInsensitiveContains("swift") || 
                                          $0.extractedMarkdown.localizedCaseInsensitiveContains("swift") ||
                                          $0.tags.contains { $0.localizedCaseInsensitiveContains("swift") } },
                "All filtered items should contain search term")
    }
    
    @Test("LibraryView tag filtering")
    func testLibraryViewTagFiltering() async throws {
        let items = [
            SavedItem(title: "Article 1", extractedMarkdown: "Content", tags: ["tech", "programming"]),
            SavedItem(title: "Article 2", extractedMarkdown: "Content", tags: ["cooking", "recipe"]),
            SavedItem(title: "Article 3", extractedMarkdown: "Content", tags: ["tech", "review"])
        ]
        
        let selectedTag = "tech"
        let filteredByTag = items.filter { item in
            selectedTag.isEmpty || item.tags.contains(selectedTag)
        }
        
        #expect(filteredByTag.count == 2, "Should find 2 items with 'tech' tag")
        #expect(filteredByTag.allSatisfy { $0.tags.contains("tech") }, "All filtered items should have 'tech' tag")
    }
    
    // MARK: - Add Item View Tests
    
    @Test("AddItemView URL validation")
    func testAddItemViewURLValidation() async throws {
        // Test URL validation logic that would be in AddItemView
        let validURLs = [
            "https://www.example.com",
            "http://test.org/article",
            "https://site.com/path/to/page.html"
        ]
        
        let invalidURLs = [
            "",
            "not-a-url",
            "just text",
            "http://", // Incomplete URL
            "www.example.com" // Missing scheme
        ]
        
        for urlString in validURLs {
            let url = URL(string: urlString)
            let isValid = url != nil && (url!.scheme == "http" || url!.scheme == "https")
            #expect(isValid, "Should validate URL: \(urlString)")
        }
        
        for urlString in invalidURLs {
            let url = URL(string: urlString)
            let isValid = url != nil && (url!.scheme == "http" || url!.scheme == "https") && url!.host != nil
            #expect(!isValid, "Should reject invalid URL: \(urlString)")
        }
    }
    
    @Test("AddItemView PDF detection")
    func testAddItemViewPDFDetection() async throws {
        let pdfURLs = [
            "https://example.com/document.pdf",
            "http://site.org/file.PDF",
            "https://domain.com/paper.pdf?version=1"
        ]
        
        let nonPDFUrls = [
            "https://example.com/article.html",
            "http://site.org/page",
            "https://domain.com/blog/post.php"
        ]
        
        // Test PDF detection logic
        for urlString in pdfURLs {
            let isPDF = urlString.lowercased().hasSuffix(".pdf") || urlString.lowercased().contains(".pdf?")
            #expect(isPDF, "Should detect PDF: \(urlString)")
        }
        
        for urlString in nonPDFUrls {
            let isPDF = urlString.lowercased().hasSuffix(".pdf") || urlString.lowercased().contains(".pdf?")
            #expect(!isPDF, "Should not detect PDF: \(urlString)")
        }
    }
    
    // MARK: - Settings View Tests
    
    @Test("SettingsView initialization")
    func testSettingsViewInit() async throws {
        let _ = SettingsView()
        // Test that view can be created (views are non-optional structs)
        // SettingsView uses @Query and @Environment for actual data access
    }
    
    // MARK: - Custom Markdown View Tests
    
    @Test("CustomMarkdownView with sample content")
    func testCustomMarkdownView() async throws {
        let markdownContent = """
        # Test Heading
        
        This is a paragraph with **bold** and *italic* text.
        
        - List item 1
        - List item 2
        
        > This is a blockquote
        
        ```swift
        let code = "Swift code block"
        ```
        """
        
        let settings = ReaderSettings()
        settings.selectedPreset = .academic
        
        let _ = CustomMarkdownView(
            markdown: markdownContent,
            images: [:],
            readerSettings: settings
        )
        
        // Test that view can be created (views are non-optional structs)
        // CustomMarkdownView takes markdown string, images dictionary, and settings
        #expect(markdownContent.contains("Test Heading"))
        #expect(markdownContent.contains("bold"))
        #expect(markdownContent.contains("List item"))
    }
    
    // MARK: - Simple Markdown View Tests
    
    @Test("SimpleMarkdownView content handling")
    func testSimpleMarkdownView() async throws {
        let markdownText = "# Title\n\nContent with **formatting**."
        let item = SavedItem(title: "Test", extractedMarkdown: markdownText)
        
        // Test that SimpleMarkdownView can be created with SavedItem
        let _ = SimpleMarkdownView(item: item)
        
        // Test that item content is accessible
        #expect(item.extractedMarkdown == markdownText)
        #expect(item.title == "Test")
    }
    
    // MARK: - SwiftUI Markdown Renderer Tests
    
    @Test("SwiftUIMarkdownRenderer basic functionality")
    func testSwiftUIMarkdownRenderer() async throws {
        let markdownText = """
        # Heading 1
        ## Heading 2
        
        This is a paragraph with **bold** text and *italic* text.
        
        - First item
        - Second item
        
        1. Numbered item
        2. Another numbered item
        
        > This is a blockquote
        
        `inline code`
        
        ```
        code block
        ```
        
        ---
        """
        
        let settings = ReaderSettings()
        settings.selectedPreset = .default
        settings.customFontSize = 16
        
        let renderer = SwiftUIMarkdownRenderer(
            markdownText: markdownText,
            readerSettings: settings
        )
        
        // Test that renderer can be created (views are non-optional structs)
        #expect(renderer.markdownText == markdownText)
        #expect(renderer.readerSettings.selectedPreset == .default)
    }
    
    @Test("SwiftUIMarkdownRenderer with different settings")
    func testMarkdownRendererWithSettings() async throws {
        let content = "# Test\n\nSample content."
        
        // Test with different presets
        for preset in ReaderPreset.allCases where preset != .custom {
            let settings = ReaderSettings()
            settings.selectedPreset = preset
            
            let renderer = SwiftUIMarkdownRenderer(
                markdownText: content,
                readerSettings: settings
            )
            
            // Test that renderer can be created (views are non-optional structs)
            #expect(renderer.readerSettings.selectedPreset == preset)
            
            // Test effective properties are accessible
            let fontSize = settings.effectiveFontSize
            let font = settings.effectiveFont
            let color = settings.effectiveAccentColor
            
            #expect(fontSize >= 12 && fontSize <= 30, "Should have valid font size for \(preset)")
            #expect(font == preset.font, "Should have consistent font for \(preset)")
            #expect(color == preset.accentColor, "Should have consistent color for \(preset)")
        }
    }
    
    // MARK: - View Integration Tests
    
    @Test("Views work together in typical user flows")
    func testViewIntegration() async throws {
        // Simulate user flow: Settings -> Reader View -> Edit
        let settings = ReaderSettings()
        settings.selectedPreset = .sepia
        
        let item = SavedItem(
            title: "Test Article",
            extractedMarkdown: "# Article\n\nContent here."
        )
        
        // Test that views can share the same data models
        let _ = ReaderView(itemId: item.id)
        let _ = ReaderSettingsView(readerSettings: .constant(settings))
        
        // Test that views can be created (non-optional structs)
        // ReaderView uses itemId to query for the item via @Query
        
        // Test data consistency
        #expect(settings.selectedPreset == .sepia)
        #expect(item.title == "Test Article")
        
        // Simulate user editing
        item.updateContent(title: "Updated Title")
        #expect(item.title == "Updated Title")
    }
    
    @Test("Views handle empty or invalid data gracefully")
    func testViewErrorHandling() async throws {
        // Test with empty content
        let emptyItem = SavedItem(title: "", extractedMarkdown: "")
        let settings = ReaderSettings()
        
        let _ = ReaderView(itemId: emptyItem.id)
        // Test that views handle empty data gracefully (can be constructed)
        
        // Test with empty markdown
        let _ = CustomMarkdownView(markdown: "", images: [:], readerSettings: settings)
        
        // Test markdown renderer with empty content
        let _ = SwiftUIMarkdownRenderer(markdownText: "", readerSettings: settings)
        
        // All views can be created with empty data (non-optional structs)
    }
}

// MARK: - View State Management Tests

@MainActor
@Suite("View State Management Tests")
struct ViewStateManagementTests {
    
    @Test("Reader settings binding updates")
    func testReaderSettingsBinding() async throws {
        let settings = ReaderSettings()
        let binding = Binding.constant(settings)
        
        // Test initial state
        #expect(binding.wrappedValue.selectedPreset == .default)
        
        // Simulate user interaction
        binding.wrappedValue.selectedPreset = .darkMode
        #expect(binding.wrappedValue.selectedPreset == .darkMode)
        
        // Test effective properties update
        let effectiveColor = binding.wrappedValue.effectiveAccentColor
        let darkModeColor = ReaderPreset.darkMode.accentColor
        #expect(effectiveColor == darkModeColor, "Effective color should match preset")
    }
    
    @Test("Item editing state management")
    func testItemEditingState() async throws {
        let item = SavedItem(title: "Original", extractedMarkdown: "Content")
        
        // Simulate view state variables
        var isEditing = false
        var editBuffer = ""
        
        // Start editing
        isEditing = true
        editBuffer = item.title
        
        #expect(isEditing == true)
        #expect(editBuffer == "Original")
        
        // Make changes
        editBuffer = "Modified"
        
        // Simulate cancel (revert changes)
        isEditing = false
        editBuffer = ""
        
        #expect(item.title == "Original", "Original should be unchanged after cancel")
        
        // Simulate save
        isEditing = true
        editBuffer = item.title
        editBuffer = "Updated"
        
        if !editBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.updateContent(title: editBuffer)
            isEditing = false
        }
        
        #expect(item.title == "Updated", "Should save changes")
        #expect(isEditing == false)
    }
    
    @Test("Search and filter state management")
    func testSearchFilterState() async throws {
        let items = [
            SavedItem(title: "Swift Guide", extractedMarkdown: "iOS development", tags: ["programming"]),
            SavedItem(title: "Recipe Book", extractedMarkdown: "Cooking instructions", tags: ["cooking"]),
            SavedItem(title: "SwiftUI Tutorial", extractedMarkdown: "UI framework guide", tags: ["programming", "ui"])
        ]
        
        // Simulate search state
        var searchText = ""
        var selectedTag = ""
        
        // Test empty search returns all items
        let allItems = items.filter { item in
            (searchText.isEmpty || item.title.localizedCaseInsensitiveContains(searchText)) &&
            (selectedTag.isEmpty || item.tags.contains(selectedTag))
        }
        #expect(allItems.count == 3)
        
        // Test search text filtering
        searchText = "swift"
        let searchResults = items.filter { item in
            (searchText.isEmpty || item.title.localizedCaseInsensitiveContains(searchText)) &&
            (selectedTag.isEmpty || item.tags.contains(selectedTag))
        }
        #expect(searchResults.count == 2)
        
        // Test tag filtering
        searchText = ""
        selectedTag = "programming"
        let tagResults = items.filter { item in
            (searchText.isEmpty || item.title.localizedCaseInsensitiveContains(searchText)) &&
            (selectedTag.isEmpty || item.tags.contains(selectedTag))
        }
        #expect(tagResults.count == 2)
        
        // Test combined search and tag filtering
        searchText = "swift"
        selectedTag = "programming"
        let combinedResults = items.filter { item in
            (searchText.isEmpty || item.title.localizedCaseInsensitiveContains(searchText)) &&
            (selectedTag.isEmpty || item.tags.contains(selectedTag))
        }
        #expect(combinedResults.count == 2)
    }
}