import Foundation

/// In-memory cache for decoded `ReaderDocument` values keyed by item ID.
///
/// Decoding large articles from JSON is expensive (measurable lag when opening
/// a long article a second time). This cache avoids re-decoding when the same
/// item is opened repeatedly. It is bounded by a simple LRU policy so memory
/// usage stays predictable for users who read many articles in one session.
final class ReaderDocumentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [UUID: ReaderDocument]()
    private var accessOrder = [UUID]()
    private let capacity: Int

    init(capacity: Int = 16) {
        self.capacity = capacity
    }

    func get(_ id: UUID) -> ReaderDocument? {
        lock.lock()
        defer { lock.unlock() }
        guard let document = storage[id] else { return nil }
        touch(id)
        return document
    }

    func set(_ id: UUID, document: ReaderDocument) {
        lock.lock()
        defer { lock.unlock() }
        storage[id] = document
        touch(id)
        evictIfNeeded()
    }

    func invalidate(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: id)
        accessOrder.removeAll { $0 == id }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        accessOrder.removeAll()
    }

    private func touch(_ id: UUID) {
        accessOrder.removeAll { $0 == id }
        accessOrder.append(id)
    }

    private func evictIfNeeded() {
        while accessOrder.count > capacity, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }
}
