import Foundation
import SwiftUI

public struct ImageMetadata: Codable, Sendable {
    public let uuid: UUID
    public let filename: String
    public let width: Int
    public let height: Int
    public let byteCount: Int
    public let sourceURL: String?
    public let createdAt: Date
    public var lastAccessed: Date
    
    public init(uuid: UUID, filename: String, width: Int, height: Int, byteCount: Int, sourceURL: String? = nil) {
        self.uuid = uuid
        self.filename = filename
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.sourceURL = sourceURL
        self.createdAt = Date()
        self.lastAccessed = Date()
    }
    
    public var domain: String? {
        guard let sourceURL = sourceURL, let url = URL(string: sourceURL) else { return nil }
        return url.host()
    }
}

public final class ImageCacheService: @unchecked Sendable {
    public static let shared = ImageCacheService()
    
    private let containerURL: URL
    private let imagesURL: URL
    private let indexURL: URL
    
    // Thread-safe synchronization
    private let lock = NSLock()
    
    // Simple in-memory metadata cache
    private var metadataCache: [UUID: ImageMetadata] = [:]
    private var sourceURLToUUID: [String: UUID] = [:]
    
    // Domain-based download tracking
    private var pendingDownloads: Set<String> = [] // keyed by URL.absoluteString
    private var domainStats: [String: DomainImageStats] = [:]
    
    private init() {
        // Use App Group container for sharing between app and extensions
        let groupIdentifier = "group.com.ryanleewilliams.stower"
        self.containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appendingPathComponent("Library")
            .appendingPathComponent("Caches")
            .appendingPathComponent("StowerImages") 
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("StowerImages")
        
        self.imagesURL = containerURL.appendingPathComponent("images")
        self.indexURL = containerURL.appendingPathComponent("index.json")
        
        setupDirectories()
        loadMetadataIndex()
    }
    
    private func setupDirectories() {
        do {
            try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
            print("📁 ImageCacheService: Created cache directories at \(containerURL.path)")
        } catch {
            print("❌ ImageCacheService: Failed to create cache directories: \(error)")
        }
    }
    
    private func loadMetadataIndex() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            print("📄 ImageCacheService: No existing index found, starting fresh")
            return
        }
        
        do {
            let data = try Data(contentsOf: indexURL)
            let metadata = try JSONDecoder().decode([ImageMetadata].self, from: data)
            
            for item in metadata {
                metadataCache[item.uuid] = item
                if let sourceURL = item.sourceURL {
                    sourceURLToUUID[sourceURL] = item.uuid
                }
            }
            
            print("📄 ImageCacheService: Loaded \(metadata.count) items from index")
        } catch {
            print("❌ ImageCacheService: Failed to load index: \(error)")
        }
    }
    
    private func saveMetadataIndex() {
        do {
            let metadata = Array(metadataCache.values)
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: indexURL)
            print("💾 ImageCacheService: Saved index with \(metadata.count) items")
        } catch {
            print("❌ ImageCacheService: Failed to save index: \(error)")
        }
    }
    
    // MARK: - Public API
    
    public func store(data: Data, sourceURL: URL? = nil, format: String = "jpg", uuid: UUID? = nil) async -> UUID? {
        // Check if we already have this image by URL
        if let sourceURL = sourceURL?.absoluteString {
            let existingUUID = lock.withLock { sourceURLToUUID[sourceURL] }
            if let existingUUID = existingUUID {
                print("🔄 ImageCacheService: Image already cached for URL: \(sourceURL)")
                return existingUUID
            }
        }
        
        let uuid = uuid ?? UUID()
        let filename = "\(uuid.uuidString).\(format)"
        let fileURL = imagesURL.appendingPathComponent(filename)
        
        do {
            try data.write(to: fileURL)
            
            // Get image dimensions
            let (width, height) = await getImageDimensions(from: data)
            
            // Create metadata
            let metadata = ImageMetadata(
                uuid: uuid,
                filename: filename,
                width: width,
                height: height,
                byteCount: data.count,
                sourceURL: sourceURL?.absoluteString
            )
            
            // Update caches
            lock.withLock {
                metadataCache[uuid] = metadata
                if let sourceURL = sourceURL?.absoluteString {
                    sourceURLToUUID[sourceURL] = uuid
                }
            }
            
            // Update domain stats
            if let domain = sourceURL?.host() {
                updateDomainStats(for: domain, bytesAdded: data.count)
            }
            
            saveMetadataIndex()
            
            print("💾 ImageCacheService: Stored image \(uuid) (\(data.count) bytes, \(width)x\(height))")
            return uuid
        } catch {
            print("❌ ImageCacheService: Failed to store image: \(error)")
            return nil
        }
    }
    
    public func image(for uuid: UUID) async -> Data? {
        guard let metadata = metadataCache[uuid] else {
            print("❌ ImageCacheService: No metadata found for UUID: \(uuid)")
            return nil
        }
        
        let fileURL = imagesURL.appendingPathComponent(metadata.filename)
        
        do {
            let data = try Data(contentsOf: fileURL)
            
            // Update access time
            metadataCache[uuid]?.lastAccessed = Date()
            
            print("✅ ImageCacheService: Retrieved image \(uuid) (\(data.count) bytes)")
            return data
        } catch {
            print("❌ ImageCacheService: Failed to load image \(uuid): \(error)")
            return nil
        }
    }
    
    public func metadata(for uuid: UUID) -> ImageMetadata? {
        return lock.withLock { metadataCache[uuid] }
    }
    
    public func findUUID(for sourceURL: URL) -> UUID? {
        return lock.withLock { sourceURLToUUID[sourceURL.absoluteString] }
    }
    
    public func totalSize() -> Int {
        return lock.withLock { metadataCache.values.reduce(0) { $0 + $1.byteCount } }
    }
    
    public func imageCount() -> Int {
        return lock.withLock { metadataCache.count }
    }
    
    public func clearCache() {
        do {
            // Remove all image files
            let imageFiles = try FileManager.default.contentsOfDirectory(at: imagesURL, includingPropertiesForKeys: nil)
            for fileURL in imageFiles {
                try FileManager.default.removeItem(at: fileURL)
            }
            
            // Clear index
            try FileManager.default.removeItem(at: indexURL)
            
            // Clear in-memory caches
            metadataCache.removeAll()
            sourceURLToUUID.removeAll()
            domainStats.removeAll()
            pendingDownloads.removeAll()
            
            print("🗑️ ImageCacheService: Cleared all cached images")
        } catch {
            print("❌ ImageCacheService: Failed to clear cache: \(error)")
        }
    }
    
    // MARK: - Domain-Based Image Management
    
    /// Downloads an image if permitted by domain settings
    public enum DownloadOutcome: Sendable {
        case skipped(reason: String)
        case alreadyCached(uuid: UUID, width: Int, height: Int)
        case downloaded(uuid: UUID, width: Int, height: Int)
        case failed(ImageDownloadError)
    }

    public func downloadImageIfPermitted(
        from url: URL,
        settings: ImageDownloadSettingsSnapshot,
        uuid: UUID? = nil
    ) async -> DownloadOutcome {
        let domain = url.host() ?? "unknown"
        
        // Check if already downloading
        let urlKey = url.absoluteString
        guard !pendingDownloads.contains(urlKey) else {
            print("🔄 ImageCacheService: Image already downloading for URL: \(urlKey)")
            return .skipped(reason: "Already downloading")
        }
        
        // Check download permissions
        let decision = settings.shouldDownloadImages(for: domain)
        guard decision.shouldDownload else {
            print("⏭️ ImageCacheService: Skipping download from \(domain): \(decision.reason)")
            return .skipped(reason: decision.reason)
        }
        
        // Check if we already have this image
        if let existingUUID = findUUID(for: url) {
            print("✅ ImageCacheService: Image already exists for \(url.absoluteString)")
            if let meta = metadata(for: existingUUID) {
                return .alreadyCached(uuid: existingUUID, width: meta.width, height: meta.height)
            } else {
                return .alreadyCached(uuid: existingUUID, width: 0, height: 0)
            }
        }
        
        // Start download
        pendingDownloads.insert(urlKey)
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            // Check size limits
            let sizeKB = data.count / 1024
            if sizeKB > settings.maxImageSizeKB {
                throw ImageDownloadError.imageTooLarge(sizeKB: sizeKB, maxKB: settings.maxImageSizeKB)
            }
            
            // Determine format from response
            let mimeType = (response as? HTTPURLResponse)?.mimeType ?? "image/jpeg"
            let format = mimeType.contains("png") ? "png" : "jpg"
            
            // Store in cache with the specified UUID if provided
            if let storedUUID = await store(data: data, sourceURL: url, format: format, uuid: uuid) {
                let finalUUID = storedUUID
                print("✅ ImageCacheService: Downloaded and cached image \(finalUUID) from \(domain)")
                pendingDownloads.remove(urlKey)
                if let meta = metadata(for: finalUUID) {
                    return .downloaded(uuid: finalUUID, width: meta.width, height: meta.height)
                } else {
                    return .downloaded(uuid: finalUUID, width: 0, height: 0)
                }
            } else {
                throw ImageDownloadError.storageFailure
            }
            
        } catch {
            print("❌ ImageCacheService: Failed to download image from \(url.absoluteString): \(error)")
            pendingDownloads.remove(urlKey)
            return .failed(error as? ImageDownloadError ?? .networkError(error))
        }
    }
    
    /// Gets domain statistics for settings UI
    public func getDomainStats(for domain: String) -> DomainImageStats {
        if let stats = domainStats[domain] {
            return stats
        }
        
        // Calculate stats on demand
        let domainImages = metadataCache.values.filter { metadata in
            if let sourceURL = metadata.sourceURL, let url = URL(string: sourceURL) {
                return url.host() == domain
            }
            return false
        }
        
        let stats = DomainImageStats(
            domain: domain,
            imageCount: domainImages.count,
            totalBytes: domainImages.reduce(0) { $0 + $1.byteCount }
        )
        
        domainStats[domain] = stats
        return stats
    }
    
    /// Gets all domain statistics
    public func getAllDomainStats() -> [DomainImageStats] {
        let domains = Set(metadataCache.values.compactMap { metadata in
            if let sourceURL = metadata.sourceURL, let url = URL(string: sourceURL) {
                return url.host()
            }
            return nil
        })
        
        return domains.map { getDomainStats(for: $0) }.sorted { $0.totalBytes > $1.totalBytes }
    }
    
    /// Clears images for a specific domain
    public func clearImages(for domain: String) {
        let domainImages = metadataCache.filter { (uuid, metadata) in
            if let sourceURL = metadata.sourceURL, let url = URL(string: sourceURL) {
                return url.host() == domain
            }
            return false
        }
        
        for (uuid, metadata) in domainImages {
            let fileURL = imagesURL.appendingPathComponent(metadata.filename)
            try? FileManager.default.removeItem(at: fileURL)
            metadataCache.removeValue(forKey: uuid)
            
            if let sourceURL = metadata.sourceURL {
                sourceURLToUUID.removeValue(forKey: sourceURL)
            }
        }
        
        domainStats.removeValue(forKey: domain)
        saveMetadataIndex()
        
        print("🗑️ ImageCacheService: Cleared \(domainImages.count) images for domain: \(domain)")
    }
    
    /// Checks if an image needs to be downloaded
    public func needsDownload(for imageRef: SavedImageRef) -> Bool {
        return !imageRef.hasLocalFile && imageRef.shouldRetryDownload
    }
    
    // MARK: - Private Helpers
    
    private func updateDomainStats(for domain: String, bytesAdded: Int) {
        if var stats = domainStats[domain] {
            stats.imageCount += 1
            stats.totalBytes += bytesAdded
            domainStats[domain] = stats
        } else {
            domainStats[domain] = DomainImageStats(
                domain: domain,
                imageCount: 1,
                totalBytes: bytesAdded
            )
        }
    }
    
    private func getImageDimensions(from data: Data) async -> (width: Int, height: Int) {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              let width = imageProperties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = imageProperties[kCGImagePropertyPixelHeight as String] as? Int else {
            return (width: 0, height: 0)
        }
        
        return (width: width, height: height)
    }
}

// MARK: - Supporting Types

public struct DomainImageStats {
    public let domain: String
    public var imageCount: Int
    public var totalBytes: Int
    
    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(totalBytes))
    }
    
    public var averageSize: Int {
        guard imageCount > 0 else { return 0 }
        return totalBytes / imageCount
    }
}

public enum ImageDownloadError: LocalizedError {
    case imageTooLarge(sizeKB: Int, maxKB: Int)
    case storageFailure
    case networkError(Error)
    
    public var errorDescription: String? {
        switch self {
        case .imageTooLarge(let sizeKB, let maxKB):
            return "Image too large: \(sizeKB)KB (max: \(maxKB)KB)"
        case .storageFailure:
            return "Failed to store image in cache"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
