import Dependencies
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct DocumentsDirectoryTests {
    @Test
    func testsNeverUseTheRealDocumentsDirectory() {
        let real = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let archive = AssetArchiver.archiveDirectory(for: UUID(1))

        #expect(!archive.path.hasPrefix(real.path))
        #expect(archive.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!MediaResolutionClient.imageStorageDirectory.path.hasPrefix(real.path))
    }

    @Test
    func archivePathsFollowAnOverriddenDirectory() {
        let root = URL(fileURLWithPath: "/tmp/stower-override", isDirectory: true)
        let id = UUID(2)

        let archive = withDependencies {
            $0.stowerDocumentsDirectory = root
        } operation: {
            AssetArchiver.archiveDirectory(for: id)
        }

        #expect(archive.path == "/tmp/stower-override/StowerArchive/\(id.uuidString)")
    }
}
