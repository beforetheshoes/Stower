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
}

public final class ImageCacheService: ObservableObject {
    @MainActor public static let shared = ImageCacheService()
    
    private let containerURL: URL
    private let imagesURL: URL
    private let indexURL: URL
    
    // Simple in-memory metadata cache
    private var metadataCache: [UUID: ImageMetadata] = [:]
    private var sourceURLToUUID: [String: UUID] = [:]
    
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
    
    public func store(data: Data, sourceURL: URL? = nil, format: String = "jpg") async -> UUID? {
        // Check if we already have this image by URL
        if let sourceURL = sourceURL?.absoluteString,
           let existingUUID = sourceURLToUUID[sourceURL] {
            print("🔄 ImageCacheService: Image already cached for URL: \(sourceURL)")
            return existingUUID
        }
        
        let uuid = UUID()
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
            metadataCache[uuid] = metadata
            if let sourceURL = sourceURL?.absoluteString {
                sourceURLToUUID[sourceURL] = uuid
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
        return metadataCache[uuid]
    }
    
    public func findUUID(for sourceURL: URL) -> UUID? {
        return sourceURLToUUID[sourceURL.absoluteString]
    }
    
    public func totalSize() -> Int {
        return metadataCache.values.reduce(0) { $0 + $1.byteCount }
    }
    
    public func imageCount() -> Int {
        return metadataCache.count
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
            
            print("🗑️ ImageCacheService: Cleared all cached images")
        } catch {
            print("❌ ImageCacheService: Failed to clear cache: \(error)")
        }
    }
    
    // MARK: - Helpers
    
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