import Foundation
import SwiftData

@Model
public final class SavedImageRef {
    public var id: UUID = UUID()
    public var sourceURL: URL?
    public var width: Int = 0
    public var height: Int = 0
    public var sha256: String = ""
    public var origin: ImageOrigin = ImageOrigin.web
    public var hasLocalFile: Bool = false
    // Store raw status to tolerate legacy or unknown values
    public var downloadStatusRaw: String = ImageDownloadStatus.pending.rawValue
    public var fileFormat: String = "jpg"
    public var createdAt: Date = Date()
    public var lastDownloadAttempt: Date?
    public var downloadFailureCount: Int = 0
    
    @Relationship
    public var item: SavedItem?
    
    public init(
        sourceURL: URL? = nil,
        width: Int = 0,
        height: Int = 0,
        sha256: String = "",
        origin: ImageOrigin = .web,
        fileFormat: String = "jpg"
    ) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.width = width
        self.height = height
        self.sha256 = sha256
        self.origin = origin
        self.fileFormat = fileFormat
        self.hasLocalFile = false
        self.downloadStatusRaw = ImageDownloadStatus.pending.rawValue
        self.createdAt = Date()
        self.downloadFailureCount = 0
    }
    
    public init(
        id: UUID,
        sourceURL: URL? = nil,
        width: Int = 0,
        height: Int = 0,
        sha256: String = "",
        origin: ImageOrigin = .web,
        fileFormat: String = "jpg"
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.width = width
        self.height = height
        self.sha256 = sha256
        self.origin = origin
        self.fileFormat = fileFormat
        self.hasLocalFile = false
        self.downloadStatusRaw = ImageDownloadStatus.pending.rawValue
        self.createdAt = Date()
        self.downloadFailureCount = 0
    }
    
    public var domain: String? {
        return sourceURL?.host()
    }
    
    public var shouldRetryDownload: Bool {
        guard downloadStatus == .failed else { return false }
        
        // Retry up to 3 times with exponential backoff
        let maxRetries = 3
        guard downloadFailureCount < maxRetries else { return false }
        
        // Calculate backoff time (1 hour * 2^failureCount)
        let backoffInterval: TimeInterval = 3600 * pow(2, Double(downloadFailureCount))
        
        if let lastAttempt = lastDownloadAttempt {
            return Date().timeIntervalSince(lastAttempt) > backoffInterval
        }
        
        return true
    }
    
    public func markDownloadSuccess() {
        downloadStatus = .completed
        hasLocalFile = true
        downloadFailureCount = 0
        lastDownloadAttempt = Date()
    }
    
    public func markDownloadFailure() {
        downloadStatus = .failed
        hasLocalFile = false
        downloadFailureCount += 1
        lastDownloadAttempt = Date()
    }
    
    public func markDownloadInProgress() {
        downloadStatus = .inProgress
        lastDownloadAttempt = Date()
    }

    // Computed enum view over the persisted raw value
    public var downloadStatus: ImageDownloadStatus {
        get { ImageDownloadStatus(rawValue: downloadStatusRaw) ?? .pending }
        set { downloadStatusRaw = newValue.rawValue }
    }
}

public enum ImageOrigin: String, Codable, CaseIterable, Sendable {
    case web = "web"
    case pdf = "pdf"
    case pasted = "pasted"
    case migrated = "migrated"
    
    public var displayName: String {
        switch self {
        case .web: return "Web"
        case .pdf: return "PDF"
        case .pasted: return "Pasted"
        case .migrated: return "Migrated"
        }
    }
}

public enum ImageDownloadStatus: String, Codable, CaseIterable, Sendable {
    case pending = "pending"
    case inProgress = "inProgress"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
    
    public var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .inProgress: return "Downloading"
        case .completed: return "Downloaded"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        }
    }
}
