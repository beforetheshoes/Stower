import SwiftUI
import SwiftData
import UniformTypeIdentifiers

public struct AddItemView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var title = ""
    @State private var content = ""
    @State private var tags = ""
    @State private var url = ""
    
    @State private var isAddingFromURL = false
    @State private var isShowingFilePicker = false
    @State private var selectedPDFURL: URL?
    
    private var isValidInput: Bool {
        if isAddingFromURL {
            let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmedURL.isEmpty && (URL(string: trimmedURL) != nil || isPDFURL(trimmedURL))
        } else if selectedPDFURL != nil {
            return true // PDF file selected
        } else {
            return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                   !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    
    private func isPDFURL(_ urlString: String) -> Bool {
        return urlString.lowercased().hasSuffix(".pdf")
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Picker("Input Type", selection: $isAddingFromURL) {
                            Text("Manual Text").tag(false)
                            Text("From URL").tag(true)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        
                        Button(action: {
                            isShowingFilePicker = true
                        }) {
                            HStack {
                                Image(systemName: "doc.badge.plus")
                                Text(selectedPDFURL == nil ? "Import PDF File" : "PDF: \(selectedPDFURL!.lastPathComponent)")
                                Spacer()
                                if selectedPDFURL != nil {
                                    Button("Clear") {
                                        selectedPDFURL = nil
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
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
                            Text(isPDFURL(url) ? "PDF processing will:" : "URL processing will:")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                if isPDFURL(url) {
                                    Label("Download the PDF file", systemImage: "arrow.down.circle")
                                    Label("Extract text with formatting", systemImage: "doc.text")
                                    Label("Detect headings and structure", systemImage: "textformat.alt")
                                    Label("Convert to clean Markdown", systemImage: "textformat")
                                } else {
                                    Label("Download the webpage", systemImage: "arrow.down.circle")
                                    Label("Extract the main content", systemImage: "doc.text")
                                    Label("Convert to clean Markdown", systemImage: "textformat")
                                    Label("Download and compress images", systemImage: "photo")
                                }
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
                
                if selectedPDFURL != nil {
                    Section("PDF Processing") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "doc.richtext")
                                    .foregroundStyle(.red)
                                Text("PDF Import")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Extract text with formatting", systemImage: "doc.text")
                                Label("Detect headings by font size", systemImage: "textformat.size")
                                Label("Identify lists and structure", systemImage: "list.bullet")
                                Label("Convert to readable Markdown", systemImage: "textformat")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            
                            Text("Note: Works best with text-based PDFs. Scanned documents may have limited text extraction.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                        }
                        .padding(.vertical, 4)
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
            .fileImporter(
                isPresented: $isShowingFilePicker,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        selectedPDFURL = url
                        // Reset other inputs when PDF is selected
                        isAddingFromURL = false
                        title = ""
                        content = ""
                    }
                case .failure(let error):
                    print("File picker error: \(error)")
                }
            }
        }
    }
    
    private func addItem() {
        let trimmedTags = tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        if let pdfURL = selectedPDFURL {
            // Handle PDF file import
            let item = SavedItem(
                title: pdfURL.deletingPathExtension().lastPathComponent,
                extractedMarkdown: "Processing PDF...",
                tags: trimmedTags
            )
            
            modelContext.insert(item)
            
            Task {
                await processPDF(for: item, pdfURL: pdfURL)
            }
        } else if isAddingFromURL {
            let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if let validURL = URL(string: trimmedURL) {
                let item = SavedItem(
                    url: validURL,
                    title: validURL.host() ?? "Untitled",
                    extractedMarkdown: isPDFURL(trimmedURL) ? "Processing PDF..." : "Processing...",
                    tags: trimmedTags
                )
                
                modelContext.insert(item)
                
                Task {
                    if isPDFURL(trimmedURL) {
                        await processPDFFromURL(for: item, url: validURL)
                    } else {
                        await processURL(for: item, url: validURL)
                    }
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
    private func processPDF(for item: SavedItem, pdfURL: URL) async {
        print("📄 AddItemView: Starting PDF processing for: \(pdfURL.lastPathComponent)")
        
        do {
            // Ensure we have access to the PDF file
            guard pdfURL.startAccessingSecurityScopedResource() else {
                throw PDFExtractionError.processingError("Could not access PDF file")
            }
            defer { pdfURL.stopAccessingSecurityScopedResource() }
            
            let pdfService = PDFExtractionService()
            let extractedContent = try await pdfService.extractContent(from: pdfURL)
            
            print("🎯 PDF extraction completed. Title: '\(extractedContent.title)', Markdown length: \(extractedContent.markdown.count)")
            
            item.updateContent(
                title: extractedContent.title.isEmpty ? pdfURL.deletingPathExtension().lastPathComponent : extractedContent.title,
                extractedMarkdown: extractedContent.markdown.isEmpty ? "No text content found in PDF" : extractedContent.markdown
            )
            
            print("💾 PDF item updated successfully")
            
        } catch {
            print("💥 Error processing PDF: \(error)")
            item.updateContent(
                title: "Failed to Process PDF",
                extractedMarkdown: "Failed to extract content from PDF: \(error.localizedDescription)"
            )
        }
    }
    
    @MainActor
    private func processPDFFromURL(for item: SavedItem, url: URL) async {
        print("🌐 AddItemView: Starting PDF download and processing for: \(url.absoluteString)")
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            print("📡 Downloaded PDF: \(data.count) bytes")
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📊 HTTP Status: \(httpResponse.statusCode)")
                print("📋 Content-Type: \(httpResponse.mimeType ?? "unknown")")
            }
            
            let pdfService = PDFExtractionService()
            let extractedContent = try await pdfService.extractContent(from: data)
            
            print("🎯 PDF extraction completed. Title: '\(extractedContent.title)', Markdown length: \(extractedContent.markdown.count)")
            
            item.updateContent(
                title: extractedContent.title.isEmpty ? (url.lastPathComponent.isEmpty ? "PDF Document" : url.lastPathComponent) : extractedContent.title,
                extractedMarkdown: extractedContent.markdown.isEmpty ? "No text content found in PDF" : extractedContent.markdown
            )
            
            print("💾 PDF item updated successfully")
            
        } catch {
            print("💥 Error processing PDF from URL: \(error)")
            item.updateContent(
                title: "Failed to Load PDF",
                extractedMarkdown: "Failed to download or process PDF from URL: \(error.localizedDescription)"
            )
        }
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
                
                // Process extracted content and images
                let processedMarkdown = await processImagesInContent(
                    extractedContent.markdown, 
                    imageURLs: extractedContent.images, 
                    baseURL: url
                )
                
                item.updateContent(
                    title: extractedContent.title,
                    extractedMarkdown: processedMarkdown
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
    
    // MARK: - Image Processing
    
    private func processImagesInContent(_ markdown: String, imageURLs: [String], baseURL: URL?) async -> String {
        // Extract image URLs from markdown directly
        let extractedImageURLs = extractImageURLsFromMarkdown(markdown)
        let allImageURLs = Set(imageURLs + extractedImageURLs)
        
        guard !allImageURLs.isEmpty else {
            print("📄 AddItemView: No images to process")
            return markdown
        }
        
        print("🖼️ AddItemView: Processing \(allImageURLs.count) images")
        
        let imageProcessor = ImageProcessingService()
        let imageCache = ImageCacheService.shared
        var updatedMarkdown = markdown
        
        // Process each image URL
        for imageURLString in allImageURLs {
            guard let imageURL = URL(string: imageURLString) else {
                print("❌ AddItemView: Invalid image URL: \(imageURLString)")
                continue
            }
            
            // Check if we already have this image cached
            if let existingUUID = imageCache.findUUID(for: imageURL) {
                print("🔄 AddItemView: Image already cached: \(existingUUID)")
                // Replace URL with token in markdown
                updatedMarkdown = updatedMarkdown.replacingOccurrences(
                    of: imageURL.absoluteString,
                    with: "stower://image/\(existingUUID)"
                )
                continue
            }
            
            do {
                // Download and process the image
                if let processedImage = try await imageProcessor.downloadAndProcess(url: imageURL) {
                    // Store in cache
                    if let uuid = await imageCache.store(
                        data: processedImage.data,
                        sourceURL: imageURL,
                        format: processedImage.format
                    ) {
                        print("✅ AddItemView: Cached image \(uuid) from \(imageURL.absoluteString)")
                        
                        // Replace URL with token in markdown
                        updatedMarkdown = updatedMarkdown.replacingOccurrences(
                            of: imageURL.absoluteString,
                            with: "stower://image/\(uuid)"
                        )
                    } else {
                        print("❌ AddItemView: Failed to cache processed image from \(imageURL.absoluteString)")
                    }
                } else {
                    print("❌ AddItemView: Failed to process image from \(imageURL.absoluteString)")
                }
            } catch {
                print("❌ AddItemView: Error processing image \(imageURL.absoluteString): \(error)")
            }
        }
        
        print("✅ AddItemView: Image processing complete")
        return updatedMarkdown
    }
    
    private func extractImageURLsFromMarkdown(_ markdown: String) -> [String] {
        let imagePattern = #"!\[([^\]]*)\]\(([^)]+)\)"#
        
        guard let regex = try? NSRegularExpression(pattern: imagePattern, options: []) else {
            print("❌ AddItemView: Failed to create regex for image extraction")
            return []
        }
        
        let matches = regex.matches(in: markdown, options: [], range: NSRange(markdown.startIndex..., in: markdown))
        var imageURLs: [String] = []
        
        for match in matches {
            if match.numberOfRanges >= 3 {
                let urlRange = Range(match.range(at: 2), in: markdown)!
                let urlString = String(markdown[urlRange])
                
                // Skip data URLs and stower tokens - we only want http(s) URLs
                if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
                    imageURLs.append(urlString)
                }
            }
        }
        
        print("📷 AddItemView: Extracted \(imageURLs.count) image URLs from markdown")
        return imageURLs
    }
    
    public init() {}
}

