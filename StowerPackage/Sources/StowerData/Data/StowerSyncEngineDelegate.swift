import CloudKit
import Foundation
import SQLiteData

final class StowerSyncEngineDelegate: SyncEngineDelegate {
    private let emit: @Sendable (CloudSyncStatus) -> Void

    init(emit: @escaping @Sendable (CloudSyncStatus) -> Void) {
        self.emit = emit
    }

    func syncEngine(
        _ syncEngine: SQLiteData.SyncEngine,
        accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async {
        switch changeType {
        case .signIn:
            emit(CloudSyncStatus(state: .available))
        case .signOut:
            emit(CloudSyncStatus(state: .needsLocalReset("iCloud signed out")))
        case .switchAccounts:
            emit(CloudSyncStatus(state: .needsLocalReset("iCloud account changed")))
        @unknown default:
            break
        }
    }
}
