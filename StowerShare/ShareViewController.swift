import Social
import StowerData
import UIKit
import UniformTypeIdentifiers

/// The share extension's principal view controller.
///
/// When the user taps "Save to Stower" in the system share sheet, iOS presents
/// this view controller and immediately calls `viewDidLoad`. The flow is:
///
/// 1. Show a loading state (background + spinner + "Saving to Stower…") so the
///    user gets instant feedback instead of a blank page.
/// 2. Pull the shared URL or text off the main thread via `NSItemProvider`.
/// 3. Bootstrap the shared app-group database on a background task and enqueue
///    an ingestion job so the main app processes the URL on next launch.
/// 4. Transition to a success or error state for ~0.9 seconds, then complete
///    the extension request so the sheet auto-dismisses.
///
/// Previous versions called `completeRequest` immediately after kicking off a
/// 0.2s fade-in animation — the animation never finished and the user saw a
/// "blank page". The explicit hold time below fixes that.
final class ShareViewController: UIViewController {
    private enum Phase {
        case loading
        case success
        case failure(String)
    }

    private let containerView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var hasCompleted = false
    private var loadTimeoutTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        apply(phase: .loading)
        handleSharedContent()
        startLoadTimeout()
    }

    // MARK: - UI

    private func configureUI() {
        view.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.08, alpha: 1.0)
                : UIColor(white: 0.98, alpha: 1.0)
        }

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.14, alpha: 1.0)
                : .white
        }
        containerView.layer.cornerRadius = 14
        containerView.layer.cornerCurve = .continuous

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .systemBlue
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 32, weight: .semibold
        )

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true

        containerView.addSubview(iconView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(spinner)
        view.addSubview(containerView)

        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 260),

            iconView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 24),
            iconView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),

            spinner.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            titleLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -24),
        ])
    }

    private func apply(phase: Phase) {
        switch phase {
        case .loading:
            iconView.image = nil
            iconView.isHidden = true
            spinner.startAnimating()
            titleLabel.text = "Saving to Stower…"
            titleLabel.textColor = .label
        case .success:
            spinner.stopAnimating()
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "checkmark.circle.fill")
            iconView.tintColor = .systemGreen
            titleLabel.text = "Saved to Stower"
            titleLabel.textColor = .label
        case .failure(let message):
            spinner.stopAnimating()
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")
            iconView.tintColor = .systemOrange
            titleLabel.text = message
            titleLabel.textColor = .label
        }
    }

    // MARK: - Sharing flow

    private func handleSharedContent() {
        guard let extensionContext,
              let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
            finish(with: .failure("Nothing to save."))
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

        finish(with: .failure("No URL or text in the share."))
    }

    private func processURLAttachment(_ attachment: NSItemProvider) {
        attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, error in
            guard let self else { return }
            if let error {
                self.reportFailureOnMain("Share load failed: \(error.localizedDescription)")
                return
            }
            guard let url = item as? URL else {
                self.reportFailureOnMain("Shared item isn't a URL.")
                return
            }
            self.enqueueOnBackground { try ShareIngestionClient.enqueueURL(url) }
        }
    }

    private func processTextAttachment(_ attachment: NSItemProvider) {
        attachment.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { [weak self] item, error in
            guard let self else { return }
            if let error {
                self.reportFailureOnMain("Share load failed: \(error.localizedDescription)")
                return
            }
            guard let text = item as? String else {
                self.reportFailureOnMain("Shared item isn't text.")
                return
            }
            let extractedURL = self.extractURL(from: text)
            self.enqueueOnBackground {
                if let extractedURL {
                    try ShareIngestionClient.enqueueURL(extractedURL)
                } else {
                    try ShareIngestionClient.enqueueText(text)
                }
            }
        }
    }

    /// Runs the database bootstrap + job enqueue on a detached task so the
    /// UI thread stays responsive while migrations run.
    private func enqueueOnBackground(_ work: @escaping () throws -> Void) {
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try work()
                await self?.reportSuccessOnMain()
            } catch {
                await self?.reportFailureOnMain("Couldn't save: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func reportSuccessOnMain() {
        loadTimeoutTask?.cancel()
        apply(phase: .success)
        // Hold the success state long enough to actually register visually,
        // then dismiss. 0.9s matches the system "toast" feel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.completeRequest()
        }
    }

    private func reportFailureOnMain(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.loadTimeoutTask?.cancel()
            self.apply(phase: .failure(message))
            // Hold failure state for longer so the user can actually read it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                self?.completeRequest()
            }
        }
    }

    private func extractURL(from text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        return matches?.first?.url
    }

    // MARK: - Timeout + completion

    /// If `NSItemProvider.loadItem` never calls back (which happens when the
    /// host app offers a type we declared but actually can't deliver), the
    /// extension would otherwise stay on screen as a permanent blank page.
    /// This timeout guarantees the sheet either completes or shows an error
    /// within 8 seconds regardless of what the OS does.
    private func startLoadTimeout() {
        loadTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.hasCompleted else { return }
                self.apply(phase: .failure("Save timed out."))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.completeRequest()
                }
            }
        }
    }

    private func completeRequest() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasCompleted else { return }
            self.hasCompleted = true
            self.loadTimeoutTask?.cancel()
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    private func finish(with phase: Phase) {
        apply(phase: phase)
        let hold: TimeInterval
        switch phase {
        case .loading: hold = 0.0
        case .success: hold = 0.9
        case .failure: hold = 1.8
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            self?.completeRequest()
        }
    }
}
