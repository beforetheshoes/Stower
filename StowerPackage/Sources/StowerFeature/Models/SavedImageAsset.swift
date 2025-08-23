import Foundation
import SwiftData
import CoreGraphics
import ImageIO

@Model
public final class SavedImageAsset {
    public var id: UUID = UUID()
    public var width: Int = 0
    public var height: Int = 0
    public var byteCount: Int = 0
    public var origin: ImageOrigin = ImageOrigin.pdf
    public var fileFormat: String = "jpg"
    public var createdAt: Date = Date()
    public var altText: String = ""
    
    // Store the actual image data as external storage for CloudKit sync
    @Attribute(.externalStorage)
    public var imageData: Data = Data()
    
    @Relationship
    public var item: SavedItem?
    
    public init(
        imageData: Data,
        width: Int = 0,
        height: Int = 0,
        origin: ImageOrigin = .pdf,
        fileFormat: String = "jpg",
        altText: String = ""
    ) {
        self.id = UUID()
        self.imageData = imageData
        self.width = width
        self.height = height
        self.byteCount = imageData.count
        self.origin = origin
        self.fileFormat = fileFormat
        self.altText = altText
        self.createdAt = Date()
    }
    
    public func updateImageData(_ data: Data) {
        imageData = data
        byteCount = data.count
    }
    
    /// Returns the size of the image in a human-readable format
    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(byteCount))
    }
    
    /// Returns dimensions as a string (e.g., "1920×1080")
    public var dimensionsString: String {
        return "\(width)×\(height)"
    }
}

extension SavedImageAsset {
    /// Creates an asset from image data with automatic dimension detection
    public static func create(
        from imageData: Data,
        origin: ImageOrigin = .pdf,
        fileFormat: String = "jpg",
        altText: String = ""
    ) async -> SavedImageAsset {
        let (width, height) = await getImageDimensions(from: imageData)
        
        return SavedImageAsset(
            imageData: imageData,
            width: width,
            height: height,
            origin: origin,
            fileFormat: fileFormat,
            altText: altText
        )
    }
    
    /// Get image dimensions from data using Core Graphics
    private static func getImageDimensions(from data: Data) async -> (width: Int, height: Int) {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              let width = imageProperties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = imageProperties[kCGImagePropertyPixelHeight as String] as? Int else {
            print("⚠️ SavedImageAsset: Could not determine image dimensions")
            return (width: 0, height: 0)
        }
        
        return (width: width, height: height)
    }
}
