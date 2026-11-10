import Foundation
import Synchronization

/// In-memory cache for decoded `ReaderDocument` values keyed by item ID.
///
/// Decoding large articles from JSON is expensive (measurable lag when opening
/// a long article a second time). This cache avoids re-decoding when the same
/// item is opened repeatedly. It is bounded by a simple LRU policy so memory
/// usage stays predictable for users who read many articles in one session.
final class ReaderDocumentCache: Sendable {
    private struct Storage {
        var documents = [UUID: ReaderDocument]()
        var accessOrder = [UUID]()

        mutating func touch(_ id: UUID) {
            accessOrder.removeAll { $0 == id }
            accessOrder.append(id)
        }
    }

    private let storage = Mutex(Storage())
    private let capacity: Int

    init(capacity: Int = 16) {
        self.capacity = capacity
    }

    func get(_ id: UUID) -> ReaderDocument? {
        storage.withLock { storage in
            guard let document = storage.documents[id] else { return nil }
            storage.touch(id)
            return document
        }
    }

    func set(_ id: UUID, document: ReaderDocument) {
        storage.withLock { storage in
            storage.documents[id] = document
            storage.touch(id)
            while storage.accessOrder.count > capacity, let oldest = storage.accessOrder.first {
                storage.accessOrder.removeFirst()
                storage.documents.removeValue(forKey: oldest)
            }
        }
    }

    func invalidate(_ id: UUID) {
        storage.withLock { storage in
            storage.documents.removeValue(forKey: id)
            storage.accessOrder.removeAll { $0 == id }
        }
    }

    func removeAll() {
        storage.withLock { $0 = Storage() }
    }
}
