import Dependencies
import Foundation
import OSLog
#if canImport(CloudKit)
import CloudKit
#endif

private let kAssetLogger = Logger(subsystem: "com.ryanleewilliams.stower", category: "CloudAssets")

public enum CloudAssetError: Error, Equatable, Sendable {
    /// The user's iCloud storage is full — the payload cannot be uploaded.
    case quotaExceeded
    /// No signed-in iCloud account.
    case notAuthenticated
    /// The record does not exist in the asset zone.
    case assetMissing
    /// The record exists but carried no usable payload.
    case corruptAsset
    /// Anything transient the caller should retry later.
    case transient(String)
}

/// Direct CloudKit access to the app-managed asset zone. Heavy payloads (PDF
/// originals, website import zips) live here as immutable, content-addressed
/// `StowerAsset` records — outside the SQLiteData SyncEngine, which is what
/// lets a device drop its local copy while the bytes stay in iCloud.
///
/// The zone (`StowerAssetZone`) is separate from the SyncEngine's zone so the
/// two systems never contend over record ownership.
public struct CloudAssetClient: Sendable {
    /// Uploads the file as `recordName`. Succeeds (without re-uploading) when
    /// an identical record already exists — records are content-addressed, so
    /// a same-name record IS the same content.
    public var upload: @Sendable (_ manifest: AssetManifest, _ fileURL: URL) async throws -> Void
    /// Downloads the record's payload to `destination` (replacing it).
    public var download: @Sendable (_ recordName: String, _ destination: URL) async throws -> Void
    public var exists: @Sendable (_ recordName: String) async throws -> Bool
    /// Best-effort delete; missing records are success.
    public var delete: @Sendable (_ recordName: String) async throws -> Void

    public init(
        upload: @escaping @Sendable (AssetManifest, URL) async throws -> Void,
        download: @escaping @Sendable (String, URL) async throws -> Void,
        exists: @escaping @Sendable (String) async throws -> Bool,
        delete: @escaping @Sendable (String) async throws -> Void
    ) {
        self.upload = upload
        self.download = download
        self.exists = exists
        self.delete = delete
    }

    public static let noop = Self(
        upload: { _, _ in },
        download: { _, _ in throw CloudAssetError.assetMissing },
        exists: { _ in false },
        delete: { _ in }
    )
}

#if canImport(CloudKit)
extension CloudAssetClient {
    public static func live(containerIdentifier: String) -> Self {
        let store = CloudAssetStore(containerIdentifier: containerIdentifier)
        return Self(
            upload: { manifest, fileURL in
                try await store.upload(manifest: manifest, fileURL: fileURL)
            },
            download: { recordName, destination in
                try await store.download(recordName: recordName, to: destination)
            },
            exists: { recordName in
                try await store.exists(recordName: recordName)
            },
            delete: { recordName in
                try await store.delete(recordName: recordName)
            }
        )
    }
}

/// Serializes zone creation and owns the CKDatabase handle.
actor CloudAssetStore {
    static let zoneName = "StowerAssetZone"
    static let recordType = "StowerAsset"

    private let container: CKContainer
    private var zoneReady = false

    private var database: CKDatabase { container.privateCloudDatabase }
    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    init(containerIdentifier: String) {
        self.container = CKContainer(identifier: containerIdentifier)
    }

    func upload(manifest: AssetManifest, fileURL: URL) async throws {
        try await ensureZone()
        let recordID = CKRecord.ID(recordName: manifest.recordName, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["payload"] = CKAsset(fileURL: fileURL)
        record["itemID"] = manifest.itemID.uuidString as CKRecordValue
        record["kind"] = manifest.kind.rawValue as CKRecordValue
        record["sha256"] = manifest.sha256 as CKRecordValue
        record["byteCount"] = manifest.byteCount as CKRecordValue
        record["originalFilename"] = manifest.originalFilename as CKRecordValue

        do {
            try await withRetry {
                let result = try await self.database.modifyRecords(
                    saving: [record],
                    deleting: [],
                    savePolicy: .ifServerRecordUnchanged
                )
                _ = try result.saveResults.mapValues { try $0.get() }
            }
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Content-addressed record name: an existing record with this name
            // is byte-identical content another device already uploaded.
            kAssetLogger.info("Asset \(manifest.recordName, privacy: .public) already uploaded elsewhere")
        } catch {
            throw mapped(error)
        }
    }

    func download(recordName: String, to destination: URL) async throws {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record: CKRecord
        do {
            record = try await withRetry {
                try await self.database.record(for: recordID)
            }
        } catch {
            throw mapped(error)
        }
        guard let asset = record["payload"] as? CKAsset, let assetURL = asset.fileURL else {
            throw CloudAssetError.corruptAsset
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: assetURL, to: destination)
    }

    func exists(recordName: String) async throws -> Bool {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            _ = try await withRetry {
                try await self.database.record(for: recordID)
            }
            return true
        } catch {
            if case CloudAssetError.assetMissing = mapped(error) {
                return false
            }
            throw mapped(error)
        }
    }

    func delete(recordName: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            try await withRetry {
                _ = try await self.database.deleteRecord(withID: recordID)
            }
        } catch {
            if case CloudAssetError.assetMissing = mapped(error) {
                return
            }
            throw mapped(error)
        }
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        do {
            _ = try await database.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)],
                deleting: []
            )
            zoneReady = true
        } catch {
            throw mapped(error)
        }
    }

    /// One bounded retry pass for transient CloudKit failures; the job queue
    /// provides the durable retries.
    private func withRetry<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await work()
            } catch let error as CKError where attempt < 2 && isRetryable(error) {
                attempt += 1
                let delay = error.retryAfterSeconds ?? Double(attempt * 2)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func isRetryable(_ error: CKError) -> Bool {
        switch error.code {
        case .serviceUnavailable, .requestRateLimited, .zoneBusy, .networkFailure, .networkUnavailable:
            return true
        default:
            return false
        }
    }

    private func mapped(_ error: Error) -> Error {
        guard let ckError = error as? CKError else { return error }
        switch ckError.code {
        case .quotaExceeded:
            return CloudAssetError.quotaExceeded
        case .notAuthenticated, .accountTemporarilyUnavailable:
            return CloudAssetError.notAuthenticated
        case .unknownItem, .zoneNotFound:
            return CloudAssetError.assetMissing
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return CloudAssetError.transient(ckError.localizedDescription)
        case .partialFailure:
            if let inner = ckError.partialErrorsByItemID?.values.first {
                return mapped(inner)
            }
            return error
        default:
            return error
        }
    }
}
#else
extension CloudAssetClient {
    public static func live(containerIdentifier _: String) -> Self { .noop }
}
#endif

// MARK: - Dependency Key

private enum CloudAssetClientKey: DependencyKey {
    static let liveValue: CloudAssetClient = .noop
    static let testValue: CloudAssetClient = .noop
}

extension DependencyValues {
    public var cloudAssetClient: CloudAssetClient {
        get { self[CloudAssetClientKey.self] }
        set { self[CloudAssetClientKey.self] = newValue }
    }
}
