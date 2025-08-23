import UIKit
import Social
import UniformTypeIdentifiers
import SwiftData
import StowerFeature

class ShareViewController: UIViewController {
    private var modelContainer: ModelContainer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupModelContainer()
        handleSharedContent()
    }
    
    private func setupModelContainer() {
        self.modelContainer = Persistence.shared
    }
    
    private func handleSharedContent() {
        guard let extensionContext = extensionContext,
              let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
            completeRequest()
            return
        }
        
        for inputItem in inputItems {
            guard let attachments = inputItem.attachments else { continue }
            
            for attachment in attachments {
                if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    processURLAttachment(attachment)
                    return
                } else if attachment.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                    processTextAttachment(attachment)
                    return
                }
            }
        }
        
        completeRequest()
    }
    
    private func processURLAttachment(_ attachment: NSItemProvider) {
        attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] (item, error) in
            DispatchQueue.main.async {
                if let error = error {
                    print("Error loading URL: \(error)")
                    self?.completeRequest()
                    return
                }
                
                guard let url = item as? URL else {
                    print("Failed to cast item as URL")
                    self?.completeRequest()
                    return
                }
                
                self?.saveURLItem(url)
            }
        }
    }
    
    private func processTextAttachment(_ attachment: NSItemProvider) {
        attachment.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { [weak self] (item, error) in
            DispatchQueue.main.async {
                if let error = error {
                    print("Error loading text: \(error)")
                    self?.completeRequest()
                    return
                }
                
                guard let text = item as? String else {
                    print("Failed to cast item as String")
                    self?.completeRequest()
                    return
                }
                
                // Try to extract URL from text
                if let url = self?.extractURL(from: text) {
                    self?.saveURLItem(url)
                } else {
                    self?.saveTextItem(text)
                }
            }
        }
    }
    
    private func extractURL(from text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        
        return matches?.first?.url
    }
    
    private func saveURLItem(_ url: URL) {
        guard let container = modelContainer else {
            completeRequest()
            return
        }
        
        let context = container.mainContext
        
        // Create a new SavedItem with processing status
        let item = SavedItem(
            url: url,
            title: url.host() ?? "Shared Article",
            extractedMarkdown: "Processing...",
            tags: ["shared"]
        )
        
        context.insert(item)
        
        do {
            try context.save()
            
            // Schedule background processing
            scheduleBackgroundProcessing(for: item, url: url)
            
            showSuccessMessage()
        } catch {
            print("Failed to save item: \(error)")
        }
        
        completeRequest()
    }
    
    private func saveTextItem(_ text: String) {
        guard let container = modelContainer else {
            completeRequest()
            return
        }
        
        let context = container.mainContext
        
        // Create a new SavedItem with the shared text
        let item = SavedItem(
            title: "Shared Text",
            extractedMarkdown: text,
            tags: ["shared", "text"]
        )
        
        context.insert(item)
        
        do {
            try context.save()
            showSuccessMessage()
        } catch {
            print("Failed to save text item: \(error)")
        }
        
        completeRequest()
    }
    
    private func scheduleBackgroundProcessing(for item: SavedItem, url: URL) {
        // Store processing job in UserDefaults for the main app to pick up
        let defaults = UserDefaults(suiteName: "group.com.ryanleewilliams.stower") ?? UserDefaults.standard
        var pendingJobs = defaults.array(forKey: "pendingProcessingJobs") as? [[String: String]] ?? []
        
        let job = [
            "id": item.id.uuidString,
            "url": url.absoluteString,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        pendingJobs.append(job)
        defaults.set(pendingJobs, forKey: "pendingProcessingJobs")
    }
    
    private func showSuccessMessage() {
        // Create a simple success view
        let successView = UIView()
        successView.backgroundColor = .systemGreen
        successView.layer.cornerRadius = 8
        successView.translatesAutoresizingMaskIntoConstraints = false
        
        let label = UILabel()
        label.text = "✓ Saved to Stower"
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        
        successView.addSubview(label)
        view.addSubview(successView)
        
        NSLayoutConstraint.activate([
            successView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            successView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            successView.widthAnchor.constraint(equalToConstant: 200),
            successView.heightAnchor.constraint(equalToConstant: 60),
            
            label.centerXAnchor.constraint(equalTo: successView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: successView.centerYAnchor)
        ])
        
        // Animate in
        successView.alpha = 0
        successView.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
            successView.alpha = 1
            successView.transform = .identity
        }
    }
    
    private func completeRequest() {
        DispatchQueue.main.async {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
