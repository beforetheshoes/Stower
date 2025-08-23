import SwiftUI
import SwiftData

public struct AddItemView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var title = ""
    @State private var content = ""
    @State private var tags = ""
    @State private var url = ""
    
    @State private var isAddingFromURL = false
    
    private var isValidInput: Bool {
        if isAddingFromURL {
            return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                   URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        } else {
            return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                   !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Input Type", selection: $isAddingFromURL) {
                        Text("Manual Text").tag(false)
                        Text("From URL").tag(true)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                
                if isAddingFromURL {
                    Section("URL") {
                        TextField("Enter URL...", text: $url, axis: .vertical)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            #if os(iOS)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            #endif
                            .autocorrectionDisabled()
                    }
                    
                    Section("Processing") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("URL processing will:")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Download the webpage", systemImage: "arrow.down.circle")
                                Label("Extract the main content", systemImage: "doc.text")
                                Label("Convert to clean Markdown", systemImage: "textformat")
                                Label("Download and compress images", systemImage: "photo")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Section("Article Details") {
                        TextField("Title", text: $title)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Content (Markdown or HTML)", text: $content, axis: .vertical)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .lineLimit(5, reservesSpace: true)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.blue)
                                    Text("Smart Content Detection")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Spacer()
                                }
                                
                                Text("• Markdown: Use **bold**, *italic*, # headers")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("• HTML: Paste any HTML - dangerous content will be automatically removed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("• Auto-detects format and converts HTML to secure Markdown")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                
                Section("Tags (Optional)") {
                    TextField("Enter tags separated by commas", text: $tags)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                    
                    Text("Example: tech, programming, swift")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Item")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addItem()
                    }
                    .disabled(!isValidInput)
                }
            }
        }
    }
    
    private func addItem() {
        let trimmedTags = tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        if isAddingFromURL {
            let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if let validURL = URL(string: trimmedURL) {
                let item = SavedItem(
                    url: validURL,
                    title: validURL.host() ?? "Untitled",
                    extractedMarkdown: "Processing...",
                    tags: trimmedTags
                )
                
                modelContext.insert(item)
                
                Task {
                    await processURL(for: item, url: validURL)
                }
            }
        } else {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Auto-detect if content is HTML
            if isHTMLContent(trimmedContent) {
                // Process HTML content with sanitization
                let item = SavedItem(
                    title: trimmedTitle,
                    extractedMarkdown: "Processing HTML...",
                    tags: trimmedTags
                )
                
                modelContext.insert(item)
                
                Task {
                    await processHTMLContent(for: item, htmlContent: trimmedContent)
                }
            } else {
                // Regular Markdown content
                let item = SavedItem(
                    title: trimmedTitle,
                    extractedMarkdown: trimmedContent,
                    tags: trimmedTags
                )
                
                modelContext.insert(item)
            }
        }
        
        dismiss()
    }
    
    @MainActor
    private func processURL(for item: SavedItem, url: URL) async {
        print("🌐 AddItemView: Starting URL processing for: \(url.absoluteString)")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            print("📡 Downloaded \(data.count) bytes")
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📊 HTTP Status: \(httpResponse.statusCode)")
                print("📋 Content-Type: \(httpResponse.mimeType ?? "unknown")")
            }
            
            // Try multiple encodings to handle different websites
            let htmlString: String?
            if let utf8String = String(data: data, encoding: .utf8) {
                htmlString = utf8String
                print("✅ Successfully converted to HTML string using UTF-8")
            } else if let isoString = String(data: data, encoding: .isoLatin1) {
                htmlString = isoString
                print("✅ Successfully converted to HTML string using ISO Latin-1")
            } else if let asciiString = String(data: data, encoding: .ascii) {
                htmlString = asciiString
                print("✅ Successfully converted to HTML string using ASCII")
            } else {
                htmlString = nil
                print("❌ Failed to convert data to HTML string with any encoding")
            }
            
            if let htmlString = htmlString {
                item.rawHTML = htmlString
                
                // Use ContentExtractionService for smart extraction
                let contentService = ContentExtractionService()
                let extractedContent = try await contentService.extractContent(from: htmlString, baseURL: url)
                
                print("🎯 Extraction completed. Title: '\(extractedContent.title)', Markdown length: \(extractedContent.markdown.count)")
                
                // Process images if any were found
                // Use native SwiftUI image handling - no custom processing needed  
                print("📝 Using native SwiftUI image handling")
                item.updateContent(
                    title: extractedContent.title,
                    extractedMarkdown: extractedContent.markdown
                )
                print("💾 Item updated successfully")
            } else {
                print("❌ Failed to convert data to HTML string")
                item.updateContent(
                    title: "Failed to Load",
                    extractedMarkdown: "Failed to convert downloaded data to text"
                )
            }
        } catch {
            print("💥 Error processing URL: \(error)")
            item.updateContent(
                title: "Failed to Load",
                extractedMarkdown: "Failed to fetch content from URL: \(error.localizedDescription)"
            )
        }
    }
    
    /// Detects if content contains HTML tags
    private func isHTMLContent(_ content: String) -> Bool {
        // Simple but effective HTML detection
        let htmlPatterns = [
            "<[a-zA-Z][^>]*>",           // Opening tags like <div>, <p>, <h1>
            "</[a-zA-Z][^>]*>",          // Closing tags like </div>, </p>
            "<[a-zA-Z][^>]*/>"           // Self-closing tags like <br/>, <img/>
        ]
        
        for pattern in htmlPatterns {
            if content.range(of: pattern, options: .regularExpression) != nil {
                print("🔍 Detected HTML content - found pattern: \(pattern)")
                return true
            }
        }
        
        // Also check for common HTML entities
        let htmlEntities = ["&amp;", "&lt;", "&gt;", "&quot;", "&nbsp;", "&#"]
        for entity in htmlEntities {
            if content.contains(entity) {
                print("🔍 Detected HTML content - found entity: \(entity)")
                return true
            }
        }
        
        return false
    }
    
    @MainActor
    private func processHTMLContent(for item: SavedItem, htmlContent: String) async {
        print("🔒 AddItemView: Starting HTML sanitization and conversion")
        
        do {
            let sanitizationService = HTMLSanitizationService()
            let sanitizedMarkdown = try sanitizationService.sanitizeAndConvertToMarkdown(htmlContent)
            
            print("✅ HTML sanitized and converted to Markdown (\(sanitizedMarkdown.count) characters)")
            
            // Update the item with the sanitized content
            item.updateContent(
                title: item.title, // Keep existing title
                extractedMarkdown: sanitizedMarkdown
            )
            
            print("💾 HTML content processed and saved successfully")
            
        } catch {
            print("❌ Failed to process HTML content: \(error)")
            
            // Fallback: treat as plain text
            let fallbackMarkdown = htmlContent
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            item.updateContent(
                title: item.title,
                extractedMarkdown: fallbackMarkdown.isEmpty ? "Failed to process HTML content" : fallbackMarkdown
            )
        }
    }
    
    
    public init() {}
}

