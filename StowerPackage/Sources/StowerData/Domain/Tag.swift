import Foundation

/// A user-created tag that can be applied to multiple saved items.
///
/// Tags are CloudKit-synced and case-insensitively unique by name.
public struct Tag: Equatable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var colorHex: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        name: String,
        id: UUID = UUID(),
        colorHex: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
