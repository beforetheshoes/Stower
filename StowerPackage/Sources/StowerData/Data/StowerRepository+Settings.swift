import Foundation
import SQLiteData

extension StowerRepository {
    static func _loadSettings(database: any DatabaseWriter) -> @Sendable () async throws -> ImageDownloadSettings {
        { () async throws -> ImageDownloadSettings in
            try await database.read { db -> ImageDownloadSettings in
                if let row: ImageDownloadSettingsLocalTable = try ImageDownloadSettingsLocalTable.fetchOne(db) {
                    return ImageDownloadSettings(
                        globalAutoDownload: row.globalAutoDownload,
                        askForNewSources: row.askForNewSources
                    )
                }
                return ImageDownloadSettings()
            }
        }
    }

    static func _saveSettings(database: any DatabaseWriter) -> @Sendable (ImageDownloadSettings) async throws -> Void {
        { (settings: ImageDownloadSettings) async throws in
            try await database.write { db in
                if let existing: ImageDownloadSettingsLocalTable = try ImageDownloadSettingsLocalTable.fetchOne(db) {
                    try ImageDownloadSettingsLocalTable
                        .find(existing.id)
                        .update {
                            $0.globalAutoDownload = settings.globalAutoDownload
                            $0.askForNewSources = settings.askForNewSources
                            $0.updatedAt = Date.now
                        }
                        .execute(db)
                } else {
                    try ImageDownloadSettingsLocalTable
                        .insert {
                            ImageDownloadSettingsLocalTable.Draft(
                                id: UUID(),
                                globalAutoDownload: settings.globalAutoDownload,
                                askForNewSources: settings.askForNewSources,
                                updatedAt: .now
                            )
                        }
                        .execute(db)
                }
            }
        }
    }

    static func _loadReaderAppearanceSettings(database: any DatabaseWriter) -> @Sendable () async throws -> ReaderAppearanceSettings {
        { () async throws -> ReaderAppearanceSettings in
            try await database.read { db -> ReaderAppearanceSettings in
                guard let row: ReaderAppearanceSettingsLocalTable = try ReaderAppearanceSettingsLocalTable.fetchOne(db) else {
                    return ReaderAppearanceSettings()
                }
                return ReaderAppearanceSettings(
                    fontSize: row.fontSize,
                    fontStyle: ReaderFontStyle(rawValue: row.fontStyle) ?? .newYork,
                    lineSpacing: row.lineSpacing,
                    justification: ReaderJustification(rawValue: row.justification) ?? .leading,
                    background: ReaderBackground.fromStored(row.theme),
                    primaryAccent: FlexokiHue.fromStored(row.primaryAccent, default: .blue),
                    secondaryAccent: FlexokiHue.fromStored(row.secondaryAccent, default: .purple),
                    lineWidth: row.lineWidth
                ).clamped()
            }
        }
    }

    static func _saveReaderAppearanceSettings(database: any DatabaseWriter) -> @Sendable (ReaderAppearanceSettings) async throws -> Void {
        { (settings: ReaderAppearanceSettings) async throws in
            let clamped = settings.clamped()
            try await database.write { db in
                if let existing: ReaderAppearanceSettingsLocalTable = try ReaderAppearanceSettingsLocalTable.fetchOne(db) {
                    try ReaderAppearanceSettingsLocalTable
                        .find(existing.id)
                        .update {
                            $0.fontSize = clamped.fontSize
                            $0.fontStyle = clamped.fontStyle.rawValue
                            $0.lineSpacing = clamped.lineSpacing
                            $0.justification = clamped.justification.rawValue
                            $0.theme = clamped.background.rawValue
                            $0.primaryAccent = clamped.primaryAccent.rawValue
                            $0.secondaryAccent = clamped.secondaryAccent.rawValue
                            $0.lineWidth = clamped.lineWidth
                            $0.updatedAt = Date.now
                        }
                        .execute(db)
                } else {
                    try ReaderAppearanceSettingsLocalTable
                        .insert {
                            ReaderAppearanceSettingsLocalTable.Draft(
                                id: UUID(),
                                fontSize: clamped.fontSize,
                                fontStyle: clamped.fontStyle.rawValue,
                                lineSpacing: clamped.lineSpacing,
                                justification: clamped.justification.rawValue,
                                theme: clamped.background.rawValue,
                                primaryAccent: clamped.primaryAccent.rawValue,
                                secondaryAccent: clamped.secondaryAccent.rawValue,
                                lineWidth: clamped.lineWidth,
                                updatedAt: .now
                            )
                        }
                        .execute(db)
                }
            }
        }
    }
}
