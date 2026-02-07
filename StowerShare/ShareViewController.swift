import Social
import StowerFeature
import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        handleSharedContent()
    }

    private func handleSharedContent() {
        guard let extensionContext,
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
                }
                if attachment.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                    processTextAttachment(attachment)
                    return
                }
            }
        }

        completeRequest()
    }

    private func processURLAttachment(_ attachment: NSItemProvider) {
        attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, error in
            DispatchQueue.main.async {
                guard error == nil, let url = item as? URL else {
                    self?.completeRequest()
                    return
                }
                try? ShareIngestionClient.enqueueURL(url)
                self?.showSuccessMessage()
                self?.completeRequest()
            }
        }
    }

    private func processTextAttachment(_ attachment: NSItemProvider) {
        attachment.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { [weak self] item, error in
            DispatchQueue.main.async {
                guard error == nil, let text = item as? String else {
                    self?.completeRequest()
                    return
                }

                if let url = self?.extractURL(from: text) {
                    try? ShareIngestionClient.enqueueURL(url)
                } else {
                    try? ShareIngestionClient.enqueueText(text)
                }
                self?.showSuccessMessage()
                self?.completeRequest()
            }
        }
    }

    private func extractURL(from text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        return matches?.first?.url
    }

    private func showSuccessMessage() {
        let successView = UIView()
        successView.backgroundColor = .systemGreen
        successView.layer.cornerRadius = 8
        successView.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "Saved to Stower"
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        successView.addSubview(label)
        view.addSubview(successView)

        NSLayoutConstraint.activate([
            successView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            successView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            successView.widthAnchor.constraint(equalToConstant: 220),
            successView.heightAnchor.constraint(equalToConstant: 60),
            label.centerXAnchor.constraint(equalTo: successView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: successView.centerYAnchor),
        ])

        successView.alpha = 0
        UIView.animate(withDuration: 0.2) {
            successView.alpha = 1
        }
    }

    private func completeRequest() {
        DispatchQueue.main.async {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
