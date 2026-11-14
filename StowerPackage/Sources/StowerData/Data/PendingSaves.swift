import Foundation
import SQLiteData

/// Something the user has asked to save that has not become a library item
/// yet: a URL waiting to be fetched, or a file waiting to be converted.
///
/// A save used to be invisible until capture finished, which can take many
/// seconds, so the list looked as if nothing had happened. These come from
/// the ingestion queue, which is local, so they appear the moment the save
/// is queued, whether from the app or the share extension, and they survive
/// a relaunch.
public struct PendingSave: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: IngestionJob.Kind
    /// The URL, or the staging path of an imported file.
    public let payload: String
    /// True once capture has started; false while it waits its turn.
    public let isProcessing: Bool
    public let createdAt: Date

    public init(id: UUID, kind: IngestionJob.Kind, payload: String, isProcessing: Bool, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.isProcessing = isProcessing
        self.createdAt = createdAt
    }

    /// The saves with no row in `items` yet.
    ///
    /// The item is written a moment before its job is marked complete, and
    /// the two are observed separately, so for that moment an article would
    /// otherwise be listed twice. An article saved before the job was queued
    /// does not count: saving a URL again refreshes it, and that work is
    /// still worth showing.
    public static func notYetArrived(_ pending: [PendingSave], among items: [SavedItem]) -> [PendingSave] {
        guard !pending.isEmpty else { return [] }
        var arrived = [String: Date]()
        for item in items {
            for url in [item.sourceURL, item.canonicalURL] {
                if let key = StowerRepository.normalizedURLKey(url) {
                    arrived[key] = max(arrived[key] ?? .distantPast, item.createdAt)
                }
            }
        }
        return pending.filter { save in
            guard save.kind == .url, let key = StowerRepository.normalizedURLKey(save.payload) else {
                return true
            }
            guard let arrivedAt = arrived[key] else { return true }
            return arrivedAt < save.createdAt
        }
    }
}

/// The saves in progress, newest first. Observed on its own so the queue's
/// bookkeeping writes do not re-run the library query.
public struct PendingSavesRequest: FetchKeyRequest {
    /// Kinds that end in a new library item. Text and Markdown are saved in
    /// one step and carry the whole document as their payload, so they are
    /// neither worth showing nor cheap to load.
    static let kinds: [IngestionJob.Kind] = [.url, .pdf, .epub, .website]

    public init() {}

    public func fetch(_ db: Database) throws -> [PendingSave] {
        let rows = try IngestionJobLocalTable
            .where {
                $0.kind.in(Self.kinds.map(\.rawValue))
                    && $0.status.in([
                        IngestionJob.Status.queued.rawValue,
                        IngestionJob.Status.processing.rawValue,
                    ])
            }
            .order { $0.createdAt.desc() }
            .select { ($0.id, $0.kind, $0.payload, $0.status, $0.createdAt) }
            .fetchAll(db)
        return rows.compactMap { id, kind, payload, status, createdAt in
            guard let kind = IngestionJob.Kind(rawValue: kind) else { return nil }
            return PendingSave(
                id: id,
                kind: kind,
                payload: payload,
                isProcessing: status == IngestionJob.Status.processing.rawValue,
                createdAt: createdAt
            )
        }
    }
}
