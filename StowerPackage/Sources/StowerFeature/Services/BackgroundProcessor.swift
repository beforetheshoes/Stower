import Foundation
import SwiftData

@MainActor
public class BackgroundProcessor: Observable {
    private let modelContext: ModelContext
    
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    public func processPendingJobs() {
        let defaults = UserDefaults(suiteName: "group.com.ryanleewilliams.stower") ?? UserDefaults.standard
        
        guard let pendingJobs = defaults.array(forKey: "pendingProcessingJobs") as? [[String: String]],
              !pendingJobs.isEmpty else {
            return
        }
        
        // Clear the pending jobs immediately to avoid reprocessing
        defaults.removeObject(forKey: "pendingProcessingJobs")
        
        for job in pendingJobs {
            guard let idString = job["id"],
                  let urlString = job["url"],
                  let id = UUID(uuidString: idString),
                  let url = URL(string: urlString) else {
                continue
            }
            
            processJob(id: id, url: url)
        }
    }
    
    private func processJob(id: UUID, url: URL) {
        // Find the SavedItem by ID
        let descriptor = FetchDescriptor<SavedItem>(
            predicate: #Predicate<SavedItem> { item in
                item.id == id
            }
        )
        
        do {
            let items = try modelContext.fetch(descriptor)
            guard let item = items.first else {
                print("Could not find saved item with ID: \(id)")
                return
            }
            
            // Process the URL in the background
            Task {
                await processURL(for: item, url: url)
            }
        } catch {
            print("Error fetching saved item: \(error)")
        }
    }
    
    private func processURL(for item: SavedItem, url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // Try multiple encodings to handle different websites
            let htmlString: String?
            if let utf8String = String(data: data, encoding: .utf8) {
                htmlString = utf8String
            } else if let isoString = String(data: data, encoding: .isoLatin1) {
                htmlString = isoString
            } else if let asciiString = String(data: data, encoding: .ascii) {
                htmlString = asciiString
            } else {
                htmlString = nil
            }
            
            if let htmlString = htmlString {
                item.rawHTML = htmlString
                
                // Use ContentExtractionService for smart extraction
                let contentService = ContentExtractionService()
                let extractedContent = try await contentService.extractContent(from: htmlString, baseURL: url)
                
                // Use native SwiftUI image handling - no custom processing needed
                item.updateContent(
                    title: extractedContent.title,
                    extractedMarkdown: extractedContent.markdown
                )
                
                // Save the updated item
                try modelContext.save()
                
            }
        } catch {
            item.updateContent(
                title: "Failed to Load",
                extractedMarkdown: "Failed to fetch content from URL: \(error.localizedDescription)"
            )
            
            try? modelContext.save()
        }
    }
}
