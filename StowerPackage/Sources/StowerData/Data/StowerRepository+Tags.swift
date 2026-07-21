import Foundation
import SQLiteData

extension StowerRepository {
    // MARK: Fetch

    static func _fetchTags(
        database: any DatabaseWriter
    ) -> @Sendable () async throws -> [Tag] {
        {
            try await database.read { db -> [Tag] in
                let rows: [TagSyncTable] = try TagSyncTable
                    .order { $0.name }
                    .fetchAll(db)
                return rows.map(toDomain(tag:))
            }
        }
    }

    static func _fetchTagIDs(
        database: any DatabaseWriter
    ) -> @Sendable (UUID) async throws -> [UUID] {
        { (itemID: UUID) async throws -> [UUID] in
            try await database.read { db -> [UUID] in
                let junction: [ItemTagSyncTable] = try ItemTagSyncTable
                    .where { $0.itemID.eq(itemID) }
                    .fetchAll(db)
                return junction.map(\.tagID)
            }
        }
    }

    static func _fetchTagIDsByItem(
        database: any DatabaseWriter
    ) -> @Sendable ([UUID]) async throws -> [UUID: [UUID]] {
        { (itemIDs: [UUID]) async throws -> [UUID: [UUID]] in
            guard !itemIDs.isEmpty else { return [:] }
            return try await database.read { db -> [UUID: [UUID]] in
                let junctions: [ItemTagSyncTable] = try ItemTagSyncTable
                    .where { $0.itemID.in(itemIDs) }
                    .fetchAll(db)
                let result: [UUID: [UUID]] = junctions.reduce(into: [:]) { dict, row in
                    dict[row.itemID, default: []].append(row.tagID)
                }
                return result
            }
        }
    }

    // MARK: Mutations

    static func _reconcileOrphanedTagAssignments(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable () async throws -> Int {
        {
            let removed = try await database.write { db in
                let itemIDs = Set(try SavedItemSyncTable.fetchAll(db).map(\.id))
                let tagIDs = Set(try TagSyncTable.fetchAll(db).map(\.id))
                let assignments = try ItemTagSyncTable.fetchAll(db)
                var removed = 0

                for assignment in assignments
                where !itemIDs.contains(assignment.itemID) || !tagIDs.contains(assignment.tagID) {
                    try ItemTagSyncTable.find(assignment.id).delete().execute(db)
                    removed += 1
                }
                return removed
            }
            if removed > 0 { scheduleSync() }
            return removed
        }
    }

    /// Creates a tag, returning the existing row if a case-insensitive name
    /// match is already present (idempotent).
    static func _createTag(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (String, String?) async throws -> Tag {
        { (rawName: String, colorHex: String?) async throws -> Tag in
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let tag: Tag = try await database.write { db -> Tag in
                // Check for case-insensitive existing name.
                let existing: [TagSyncTable] = try TagSyncTable.all.fetchAll(db)
                if let hit = existing.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    return toDomain(tag: hit)
                }
                let now = Date.now
                let draft = TagSyncTable.Draft(
                    id: UUID(),
                    name: trimmed,
                    colorHex: colorHex,
                    createdAt: now,
                    updatedAt: now
                )
                try TagSyncTable.insert { draft }.execute(db)
                return Tag(
                    name: trimmed,
                    id: draft.id ?? UUID(),
                    colorHex: colorHex,
                    createdAt: now,
                    updatedAt: now
                )
            }
            scheduleSync()
            return tag
        }
    }

    static func _renameTag(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID, String) async throws -> Void {
        { (id: UUID, newName: String) async throws in
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            let now = Date.now
            try await database.write { db in
                try TagSyncTable
                    .find(id)
                    .update {
                        $0.name = #bind(trimmed)
                        $0.updatedAt = #bind(now)
                    }
                    .execute(db)
            }
            scheduleSync()
        }
    }

    static func _deleteTag(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID) async throws -> Void {
        { (id: UUID) async throws in
            try await database.write { db in
                try ItemTagSyncTable.where { $0.tagID.eq(id) }.delete().execute(db)
                try TagSyncTable.find(id).delete().execute(db)
            }
            scheduleSync()
        }
    }

    static func _addTag(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID, UUID) async throws -> Void {
        { (itemID: UUID, tagID: UUID) async throws in
            try await database.write { db in
                // Dedupe: the unique index would reject a duplicate, but we
                // pre-check so the caller sees a clean no-op on double-add.
                let existing: [ItemTagSyncTable] = try ItemTagSyncTable
                    .where { $0.itemID.eq(itemID) && $0.tagID.eq(tagID) }
                    .fetchAll(db)
                guard existing.isEmpty else { return }
                let draft = ItemTagSyncTable.Draft(
                    id: UUID(),
                    itemID: itemID,
                    tagID: tagID,
                    createdAt: Date.now
                )
                try ItemTagSyncTable.insert { draft }.execute(db)
            }
            scheduleSync()
        }
    }

    static func _removeTag(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID, UUID) async throws -> Void {
        { (itemID: UUID, tagID: UUID) async throws in
            try await database.write { db in
                try ItemTagSyncTable
                    .where { $0.itemID.eq(itemID) && $0.tagID.eq(tagID) }
                    .delete()
                    .execute(db)
            }
            scheduleSync()
        }
    }
}
