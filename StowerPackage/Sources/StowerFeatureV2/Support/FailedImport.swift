import Foundation
import StowerData

/// A queued import that gave up, in the shape the failure banner needs.
///
/// The banner used to show only a count ("2 imports need attention"), which
/// told the user nothing about *what* failed or *why* — so a share that
/// silently failed looked identical to one that never arrived, and the only
/// available response was to share the link again and hope.
public struct FailedImport: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// What was being imported, in user terms — a host + path for URLs, a
    /// filename for PDFs and website archives, an excerpt for text.
    public let label: String
    /// Why it gave up, taken from the job's last recorded error.
    public let reason: String?

    public init(id: UUID, label: String, reason: String?) {
        self.id = id
        self.label = label
        self.reason = reason
    }

    public static func list(from jobs: [IngestionJob]) -> [FailedImport] {
        jobs.map(FailedImport.init(job:))
    }

    public init(job: IngestionJob) {
        self.id = job.id
        self.label = Self.label(for: job)
        let trimmed = job.lastError?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private static func label(for job: IngestionJob) -> String {
        switch job.kind {
        case .url, .hydrate:
            return displayURL(job.payload)
        case .pdf, .website, .hydrateWebsite:
            // Payloads are staging paths inside the App Group container.
            let name = URL(fileURLWithPath: job.payload).lastPathComponent
            return name.isEmpty ? "Imported file" : name
        case .text, .markdown, .hydrateText:
            // Payloads are JSON envelopes; the raw text is more confusing than
            // helpful, so name the kind instead.
            return job.kind == .markdown ? "Imported Markdown" : "Imported text"
        }
    }

    /// `https://www.example.com/a/b?x=1` → `example.com/a/b`. Long paths are
    /// truncated in the middle so both the site and the final path component
    /// stay readable in a single banner line.
    static func displayURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host() else {
            return trimmed
        }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path()
        guard !path.isEmpty, path != "/" else { return site }
        let combined = site + (path.hasSuffix("/") ? String(path.dropLast()) : path)
        guard combined.count > 60 else { return combined }
        return combined.prefix(34) + "…" + combined.suffix(20)
    }
}
