import Foundation
import SwiftData

@MainActor
public enum Persistence {
    public static let shared: ModelContainer = {
        do {
            let container = try ModelContainer(
                for: SavedItem.self, ImageDownloadSettings.self, SavedImageRef.self, SavedImageAsset.self,
                configurations: ModelConfiguration(
                    groupContainer: .identifier("group.com.ryanleewilliams.stower"),
                    cloudKitDatabase: .automatic
                )
            )
            container.mainContext.autosaveEnabled = true
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
}
