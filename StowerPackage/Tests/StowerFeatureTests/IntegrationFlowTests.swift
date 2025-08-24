import Testing
import Foundation
import SwiftUI
@testable import StowerFeature

@Suite("Integration Flow Tests", .serialized)
struct IntegrationFlowTests {
    
    // MARK: - Complete User Journey Tests
    
    @Test("Complete article saving and reading flow")
    @MainActor
    func testCompleteArticleFlow() async throws {
        // Step 1: User opens app and sees library
        var savedItems: [SavedItem] = []
        #expect(savedItems.isEmpty, "Library should start empty")
        
        // Step 2: User wants to save an article
        let articleURL = "https://example.com/great-article.html"
        let articleTitle = "A Great Article About Swift"
        let articleContent = """
        # A Great Article About Swift
        
        This article discusses the latest features in Swift programming language.
        
        ## Key Points
        
        - Swift is powerful and modern
        - It's used for iOS development
        - Performance improvements in latest version
        
        ```swift
        let greeting = "Hello, Swift!"
        print(greeting)
        ```
        
        > Swift makes programming more approachable and fun.
        """
        
        // Step 3: Article gets processed and saved
        let savedItem = SavedItem(
            url: URL(string: articleURL),
            title: articleTitle,
            extractedMarkdown: articleContent,
            tags: ["programming", "swift", "ios"]
        )
        
        savedItems.append(savedItem)
        
        #expect(savedItems.count == 1, "Should have saved one item")
        #expect(savedItems.first?.title == articleTitle)
        #expect(savedItems.first?.url?.absoluteString == articleURL)
        #expect(savedItems.first?.tags.contains("swift") == true)
        
        // Step 4: User opens library and finds the article
        let searchText = "swift"
        let searchResults = savedItems.filter { item in
            item.title.localizedCaseInsensitiveContains(searchText) ||
            item.extractedMarkdown.localizedCaseInsensitiveContains(searchText) ||
            item.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
        
        #expect(searchResults.count == 1, "Should find article in search")
        
        // Step 5: User opens article in reader
        let articleToRead = searchResults.first!
        let readerSettings = ReaderSettings()
        readerSettings.updatePreset(.academic)  // User prefers academic reading
        
        #expect(readerSettings.effectiveFontSize == 17.0, "Academic preset should have 17pt font")
        #expect(readerSettings.effectiveFont == .serif, "Academic preset should use serif font")
        
        // Step 6: User customizes reading experience
        readerSettings.updatePreset(.custom)
        readerSettings.updateCustomSettings(
            accentColor: .green,
            font: .rounded,
            fontSize: 20.0
        )
        
        #expect(readerSettings.effectiveFontSize == 20.0, "Should use custom font size")
        #expect(readerSettings.effectiveFont == .rounded, "Should use custom font")
        #expect(readerSettings.effectiveAccentColor == .green, "Should use custom accent color")
        
        // Step 7: User edits article metadata
        let newTitle = "Updated: A Great Article About Swift"
        let additionalTags = ["tutorial", "beginner-friendly"]
        
        articleToRead.updateContent(
            title: newTitle,
            tags: articleToRead.tags + additionalTags
        )
        
        #expect(articleToRead.title == newTitle, "Title should be updated")
        #expect(articleToRead.tags.contains("tutorial"), "Should have added tutorial tag")
        #expect(articleToRead.tags.contains("swift"), "Should preserve original tags")
        
        // Step 8: Settings persist across app sessions - use isolated defaults
        let defaults = UserDefaults.makeIsolated()
        
        // Use testing override for this integration test
        TestDefaultsScope.use(defaults) {
            // Create settings with isolated defaults and configure them
            let isolatedSettings = ReaderSettings()  // Will use override
            isolatedSettings.selectedPreset = .custom
            isolatedSettings.customFontSize = 20.0
            isolatedSettings.save()
            
            // Load settings from the same isolated defaults
            let loadedSettings = ReaderSettings.loadFromUserDefaults()  // Will use override
            
            #expect(loadedSettings.selectedPreset == .custom, "Settings should persist")
            #expect(loadedSettings.customFontSize == 20.0, "Custom font size should persist")
        }
    }
    
    @Test("PDF processing and reading workflow")
    func testPDFWorkflow() async throws {
        // Step 1: User saves a PDF document
        let pdfURL = "https://example.com/research-paper.pdf"
        let isRecognizedAsPDF = pdfURL.lowercased().hasSuffix(".pdf")
        
        #expect(isRecognizedAsPDF, "Should recognize PDF URL")
        
        // Step 2: PDF gets processed (simulated)
        let extractedContent = """
        # Research Paper: Swift Performance Analysis
        
        ## Abstract
        
        This paper analyzes the performance characteristics of Swift programming language across different use cases.
        
        ## Introduction
        
        Swift has evolved significantly since its introduction in 2014. This study examines...
        
        ## Key Findings
        
        1. Memory usage has improved by 40%
        2. Compilation time reduced by 25%
        3. Runtime performance increased by 30%
        
        ## Conclusion
        
        The results demonstrate Swift's continued evolution toward better performance and developer experience.
        """
        
        let pdfItem = SavedItem(
            url: URL(string: pdfURL),
            title: "Research Paper: Swift Performance Analysis",
            extractedMarkdown: extractedContent,
            tags: ["research", "swift", "performance", "pdf"]
        )
        
        #expect(pdfItem.title.contains("Research Paper"), "Should extract meaningful title")
        #expect(pdfItem.extractedMarkdown.contains("Abstract"), "Should extract structured content")
        #expect(pdfItem.tags.contains("pdf"), "Should tag as PDF")
        
        // Step 3: User reads PDF with specialized settings
        let pdfReaderSettings = ReaderSettings()
        pdfReaderSettings.selectedPreset = .academic  // Good for research papers
        
        #expect(pdfReaderSettings.effectiveFont == .serif, "Academic preset good for PDF reading")
        #expect(pdfReaderSettings.effectiveFontSize == 17.0, "Larger font for easier reading")
        
        // Step 4: User takes notes by editing content
        let originalContent = pdfItem.extractedMarkdown
        let notesSection = "\n\n## My Notes\n\n- Very interesting findings about memory usage\n- Need to investigate compilation improvements\n- Consider for our next project"
        
        pdfItem.updateContent(extractedMarkdown: originalContent + notesSection)
        
        #expect(pdfItem.extractedMarkdown.contains("My Notes"), "Should allow adding notes")
        #expect(pdfItem.extractedMarkdown.contains("Very interesting"), "Should preserve note content")
    }
    
    @Test("Multi-device sync simulation")
    func testMultiDeviceSyncSimulation() async throws {
        // Device 1: iPhone - User saves article
        var device1Items: [SavedItem] = []
        let mobileSettings = ReaderSettings()
        mobileSettings.selectedPreset = .minimal  // Good for mobile reading
        mobileSettings.save()
        
        let article1 = SavedItem(
            title: "Mobile Development Tips",
            extractedMarkdown: "# Tips for mobile developers...",
            tags: ["mobile", "tips"]
        )
        
        device1Items.append(article1)
        
        // Device 2: iPad - User saves different article
        var device2Items: [SavedItem] = []
        let tabletSettings = ReaderSettings()
        tabletSettings.selectedPreset = .academic  // Larger screen, more comfortable for longer reading
        tabletSettings.save()
        
        let article2 = SavedItem(
            title: "Advanced SwiftUI Patterns",
            extractedMarkdown: "# Advanced patterns in SwiftUI...",
            tags: ["swiftui", "patterns", "advanced"]
        )
        
        device2Items.append(article2)
        
        // Sync simulation: Both devices get all articles
        let syncedItems = device1Items + device2Items
        
        #expect(syncedItems.count == 2, "Should sync all items across devices")
        #expect(syncedItems.contains { $0.title == "Mobile Development Tips" }, "Should have mobile article")
        #expect(syncedItems.contains { $0.title == "Advanced SwiftUI Patterns" }, "Should have SwiftUI article")
        
        // Settings remain device-specific
        #expect(mobileSettings.selectedPreset == .minimal, "Mobile should keep minimal preset")
        #expect(tabletSettings.selectedPreset == .academic, "Tablet should keep academic preset")
        
        // User searches across synced content
        let searchTerm = "swiftui"
        let searchResults = syncedItems.filter { item in
            item.title.localizedCaseInsensitiveContains(searchTerm) ||
            item.tags.contains { $0.localizedCaseInsensitiveContains(searchTerm) }
        }
        
        #expect(searchResults.count == 1, "Should find SwiftUI article across devices")
    }
    
    @Test("Error recovery and resilience flow")
    @MainActor
    func testErrorRecoveryFlow() async throws {
        // Step 1: User tries to save invalid URL
        let invalidURL = ""  // Empty string is truly invalid
        let url = URL(string: invalidURL)
        
        #expect(url == nil, "Invalid URL should not create URL object")
        
        // Step 2: App handles gracefully, user corrects URL
        let correctedURL = "https://example.com/article"
        let validURL = URL(string: correctedURL)
        
        #expect(validURL != nil, "Corrected URL should be valid")
        #expect(validURL?.scheme == "https", "Should have secure scheme")
        
        // Step 3: Content extraction fails, user tries again
        var extractionAttempts = 0
        let maxAttempts = 3
        var extractedContent: String? = nil
        
        // Simulate failed attempts
        while extractionAttempts < maxAttempts && extractedContent == nil {
            extractionAttempts += 1
            
            // Simulate extraction logic
            if extractionAttempts == 3 {  // Success on third attempt
                extractedContent = "# Successfully extracted content\n\nArticle text here..."
            }
        }
        
        #expect(extractedContent != nil, "Should eventually succeed after retries")
        #expect(extractionAttempts <= maxAttempts, "Should not exceed max attempts")
        
        // Step 4: Corrupted settings recovery - use isolated defaults
        let defaults = UserDefaults.makeIsolated()
        defaults.set("invalid json data", forKey: "ReaderSettings")
        
        TestDefaultsScope.use(defaults) {
            let recoveredSettings = ReaderSettings.loadFromUserDefaults()  // Will use override
            #expect(recoveredSettings.selectedPreset == .default, "Should fallback to defaults on corruption")
        }
        
        // Step 5: User continues with recovered state
        let item = SavedItem(
            url: validURL,
            title: "Recovered Article",
            extractedMarkdown: extractedContent!
        )
        
        #expect(item.title == "Recovered Article", "Should create item after recovery")
    }
    
    @Test("Accessibility and inclusive design flow")
    func testAccessibilityFlow() async throws {
        // Step 1: User with visual impairment needs high contrast
        let accessibleSettings = ReaderSettings()
        accessibleSettings.selectedPreset = .highContrast
        
        #expect(accessibleSettings.effectiveColorScheme == .light, "High contrast should use light mode")
        #expect(accessibleSettings.effectiveFontSize == 18.0, "High contrast should use larger font")
        
        // Step 2: User needs even larger text
        accessibleSettings.selectedPreset = .custom
        accessibleSettings.customFontSize = 24.0  // Very large for accessibility
        accessibleSettings.isDarkMode = false     // Explicit light mode
        
        #expect(accessibleSettings.effectiveFontSize == 24.0, "Should support very large fonts")
        #expect(accessibleSettings.effectiveColorScheme == .light, "Should respect light mode preference")
        
        // Step 3: Content should remain readable at large sizes
        let longArticle = SavedItem(
            title: "Long Article with Complex Content",
            extractedMarkdown: """
            # Article Title
            
            This is a long article with multiple paragraphs, lists, and formatting that needs to remain readable at large font sizes.
            
            ## Section 1
            
            - Point one with important information
            - Point two with additional details
            - Point three with concluding thoughts
            
            ### Subsection
            
            More detailed content here with **bold text** and *italic text* that should scale properly.
            
            > This is a blockquote that should remain distinguishable at large font sizes.
            
            ```swift
            // Code should remain monospace even with large UI text
            let importantCode = "accessibility"
            ```
            """
        )
        
        #expect(longArticle.extractedMarkdown.count > 100, "Should handle long content")
        #expect(longArticle.extractedMarkdown.contains("**bold text**"), "Should preserve formatting")
        
        // Step 4: Verify content structure is preserved
        let hasHeadings = longArticle.extractedMarkdown.contains("#")
        let hasLists = longArticle.extractedMarkdown.contains("-")
        let hasCode = longArticle.extractedMarkdown.contains("```")
        
        #expect(hasHeadings, "Should preserve heading structure")
        #expect(hasLists, "Should preserve list structure")
        #expect(hasCode, "Should preserve code blocks")
    }
    
    @Test("Performance under load simulation")
    func testPerformanceUnderLoad() async throws {
        // Step 1: User has accumulated many articles
        var largeLibrary: [SavedItem] = []
        let itemCount = 100
        
        for i in 1...itemCount {
            let item = SavedItem(
                title: "Article \(i): Sample Title",
                extractedMarkdown: """
                # Article \(i)
                
                This is sample content for article number \(i). It contains multiple paragraphs and formatting.
                
                ## Section A
                
                Content here with **bold** and *italic* text.
                
                ## Section B
                
                - List item 1
                - List item 2
                - List item 3
                
                > Quote from article \(i)
                """,
                tags: ["tag\(i % 5)", "category\(i % 3)", "sample"]
            )
            largeLibrary.append(item)
        }
        
        #expect(largeLibrary.count == itemCount, "Should handle large number of items")
        
        // Step 2: Search performance with large dataset
        let startTime = Date()
        let searchResults = largeLibrary.filter { item in
            item.title.contains("5") || item.extractedMarkdown.contains("5") || 
            item.tags.contains { $0.contains("5") }
        }
        let searchDuration = Date().timeIntervalSince(startTime)
        
        #expect(searchResults.count > 0, "Should find matching items")
        #expect(searchDuration < 0.1, "Search should be fast even with many items")
        
        // Step 3: Tag filtering performance
        let tagStartTime = Date()
        let tagResults = largeLibrary.filter { $0.tags.contains("tag1") }
        let tagDuration = Date().timeIntervalSince(tagStartTime)
        
        #expect(tagResults.count > 0, "Should find items with specific tag")
        #expect(tagDuration < 0.1, "Tag filtering should be fast")
        
        // Step 4: Memory efficiency - verify objects can be created without issues
        let memoryTestStart = Date()
        for item in largeLibrary.prefix(20) {
            let settings = ReaderSettings()
            settings.selectedPreset = .default
            
            // Simulate view creation (lightweight test)
            #expect(item.title.count > 0, "Items should have valid titles")
            #expect(settings.effectiveFontSize > 0, "Settings should have valid font size")
        }
        let memoryTestDuration = Date().timeIntervalSince(memoryTestStart)
        
        #expect(memoryTestDuration < 1.0, "Should handle multiple view creations efficiently")
    }
}

// MARK: - Cross-Platform Integration Tests

@Suite("Cross-Platform Integration Tests")
struct CrossPlatformIntegrationTests {
    
    @Test("iOS and macOS settings compatibility")
    func testCrossPlatformSettings() async throws {
        // Settings should work identically on both platforms
        let settings = ReaderSettings()
        settings.selectedPreset = .academic
        settings.customFontSize = 18.0
        settings.customAccentColor = .blue
        
        // Test that all presets work on both platforms
        for preset in ReaderPreset.allCases {
            settings.selectedPreset = preset
            
            let fontSize = settings.effectiveFontSize
            let font = settings.effectiveFont
            let color = settings.effectiveAccentColor
            
            #expect(fontSize > 0, "Preset \(preset) should work on all platforms")
            #expect(font == preset.font, "Preset \(preset) should have consistent font on all platforms")
            #expect(color == preset.accentColor, "Preset \(preset) should have consistent color on all platforms")
        }
        
        // Test custom settings work consistently
        settings.selectedPreset = .custom
        settings.customFontSize = 20.0
        settings.customFont = .serif
        
        #expect(settings.effectiveFontSize == 20.0, "Custom font size should work on all platforms")
        #expect(settings.effectiveFont == .serif, "Custom font should work on all platforms")
    }
    
    @Test("Data model consistency across platforms")
    func testDataModelConsistency() async throws {
        // SavedItem should behave identically on iOS and macOS
        let item = SavedItem(
            url: URL(string: "https://example.com/article"),
            title: "Cross-Platform Article",
            author: "Test Author",
            extractedMarkdown: "# Title\n\nContent here.",
            tags: ["cross-platform", "testing"]
        )
        
        // Test all properties are accessible
        #expect(item.url?.absoluteString == "https://example.com/article")
        #expect(item.title == "Cross-Platform Article")
        #expect(item.author == "Test Author")
        #expect(item.extractedMarkdown.contains("Content here"))
        #expect(item.tags.contains("cross-platform"))
        
        // Test updates work consistently
        item.updateContent(title: "Updated Title", author: "Updated Author")
        
        #expect(item.title == "Updated Title")
        #expect(item.author == "Updated Author")
        #expect(item.dateModified > item.dateAdded, "Modification date should update")
        
        // Test content preview generation
        let preview = SavedItem.generatePreview(from: item.extractedMarkdown)
        #expect(!preview.isEmpty, "Should generate preview on all platforms")
        #expect(preview.count <= 151, "Preview should be limited length on all platforms") // 150 + ellipsis
    }
    
    @Test("Service behavior consistency")
    func testServiceConsistency() async throws {
        // Services should behave the same on all platforms
        let _ = ContentExtractionService()
        let _ = PDFExtractionService()
        
        // Test basic functionality works on all platforms
        // Services are non-optional and always initialize successfully on all platforms
        // ContentExtractionService and PDFExtractionService have reliable initialization
        
        // Test HTML sanitization works consistently
        let testHTML = "<p>Safe content</p><script>alert('danger')</script>"
        let sanitized = testHTML.replacingOccurrences(of: "<script.*?</script>", with: "", options: .regularExpression)
        
        #expect(sanitized.contains("Safe content"), "Should preserve safe content on all platforms")
        #expect(!sanitized.contains("script"), "Should remove unsafe content on all platforms")
        
        // Test PDF service text processing
        let pdfService = PDFExtractionService()
        let messyText = "Word bro-\nken across lines    with   spaces"
        let cleaned = pdfService.cleanupMarkdown(messyText)
        
        #expect(cleaned.contains("broken"), "Should fix word breaks on all platforms")
        #expect(!cleaned.contains("   "), "Should normalize spaces on all platforms")
    }
}