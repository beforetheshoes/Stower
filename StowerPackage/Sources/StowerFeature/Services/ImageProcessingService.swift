import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageHints: Sendable {
    public let maxDimension: Int
    public let quality: Double
    public let preferredFormat: String
    
    public init(maxDimension: Int = 1600, quality: Double = 0.8, preferredFormat: String = "jpg") {
        self.maxDimension = maxDimension
        self.quality = quality
        self.preferredFormat = preferredFormat
    }
    
    public static let low = ImageHints(maxDimension: 800, quality: 0.7)
    public static let medium = ImageHints(maxDimension: 1200, quality: 0.8)
    public static let high = ImageHints(maxDimension: 1600, quality: 0.9)
}

public struct ProcessedImage: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let format: String
    public let originalSize: Int
    public let compressedSize: Int
    
    public var compressionRatio: Double {
        guard originalSize > 0 else { return 1.0 }
        return Double(compressedSize) / Double(originalSize)
    }
}

@MainActor
public final class ImageProcessingService {
    private let session: URLSession
    private let maxDownloadSize = 10 * 1024 * 1024 // 10MB
    
    public init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 10 * 1024 * 1024, diskCapacity: 50 * 1024 * 1024)
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Image Download
    
    public func downloadImage(from url: URL) async throws -> Data {
        print("📥 ImageProcessingService: Downloading image from \(url.absoluteString)")
        
        // Check network constraints
        if await shouldSkipOnCellular(url: url) {
            throw ImageProcessingError.skippedOnCellular
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageProcessingError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw ImageProcessingError.httpError(httpResponse.statusCode)
        }
        
        guard data.count <= maxDownloadSize else {
            throw ImageProcessingError.imageTooLarge(data.count)
        }
        
        print("✅ ImageProcessingService: Downloaded \(data.count) bytes from \(url.absoluteString)")
        return data
    }
    
    // MARK: - Image Processing
    
    public func processImage(_ data: Data, hints: ImageHints = .medium) async -> ProcessedImage? {
        let originalSize = data.count
        print("🔄 ImageProcessingService: Processing image (\(originalSize) bytes) with hints: max=\(hints.maxDimension)px, quality=\(hints.quality)")
        
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              let originalWidth = imageProperties[kCGImagePropertyPixelWidth as String] as? Int,
              let originalHeight = imageProperties[kCGImagePropertyPixelHeight as String] as? Int else {
            print("❌ ImageProcessingService: Failed to read image properties")
            return nil
        }
        
        // Determine if we should keep as PNG (for small graphics) or convert to JPEG/HEIC
        let shouldKeepPNG = originalSize < 200_000 && isProbablyGraphic(width: originalWidth, height: originalHeight)
        let targetFormat = shouldKeepPNG ? "png" : hints.preferredFormat
        
        // Calculate downscale ratio
        let maxDim = max(originalWidth, originalHeight)
        let shouldDownscale = maxDim > hints.maxDimension
        
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: shouldDownscale ? hints.maxDimension : max(originalWidth, originalHeight)
        ]
        
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
            print("❌ ImageProcessingService: Failed to create thumbnail")
            return nil
        }
        
        // Convert to target format
        guard let processedData = encodeImage(thumbnail, format: targetFormat, quality: hints.quality) else {
            print("❌ ImageProcessingService: Failed to encode processed image")
            return nil
        }
        
        let finalWidth = thumbnail.width
        let finalHeight = thumbnail.height
        let finalSize = processedData.count
        
        print("✅ ImageProcessingService: Processed image \(originalWidth)x\(originalHeight) → \(finalWidth)x\(finalHeight), \(originalSize) → \(finalSize) bytes (\(Int((Double(finalSize)/Double(originalSize)) * 100))%)")
        
        return ProcessedImage(
            data: processedData,
            width: finalWidth,
            height: finalHeight,
            format: targetFormat,
            originalSize: originalSize,
            compressedSize: finalSize
        )
    }
    
    // MARK: - Download + Process Pipeline
    
    public func downloadAndProcess(url: URL, hints: ImageHints = .medium) async throws -> ProcessedImage? {
        let data = try await downloadImage(from: url)
        return await processImage(data, hints: hints)
    }
    
    // MARK: - Helper Functions
    
    private func isProbablyGraphic(width: Int, height: Int) -> Bool {
        // Small square images or very thin/wide images are likely graphics/icons
        let aspectRatio = Double(width) / Double(height)
        let isSmallSquare = width <= 200 && height <= 200 && aspectRatio > 0.5 && aspectRatio < 2.0
        let isVeryThinOrWide = aspectRatio > 5.0 || aspectRatio < 0.2
        return isSmallSquare || isVeryThinOrWide
    }
    
    private func encodeImage(_ cgImage: CGImage, format: String, quality: Double) -> Data? {
        let mutableData = CFDataCreateMutable(nil, 0)!
        
        let destinationType: CFString = switch format.lowercased() {
        case "png":
            UTType.png.identifier as CFString
        case "heic", "heif":
            UTType.heic.identifier as CFString
        default:
            UTType.jpeg.identifier as CFString
        }
        
        guard let destination = CGImageDestinationCreateWithData(mutableData, destinationType, 1, nil) else {
            return nil
        }
        
        let properties: [CFString: Any] = if format.lowercased() == "png" {
            // PNG doesn't use quality, but we can control compression
            [kCGImageDestinationLossyCompressionQuality: 1.0]
        } else {
            // JPEG/HEIC quality
            [kCGImageDestinationLossyCompressionQuality: quality]
        }
        
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        
        return mutableData as Data
    }
    
    private func shouldSkipOnCellular(url: URL) async -> Bool {
        // For now, always allow downloads
        // In the future, this could check UserDefaults for cellular preference
        // and use Network framework to detect cellular connection
        return false
    }
}

// MARK: - Error Types

public enum ImageProcessingError: LocalizedError, Sendable {
    case invalidResponse
    case httpError(Int)
    case imageTooLarge(Int)
    case skippedOnCellular
    case processingFailed
    
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .httpError(let code):
            return "HTTP error \(code)"
        case .imageTooLarge(let size):
            return "Image too large (\(size / 1024 / 1024)MB)"
        case .skippedOnCellular:
            return "Skipped download on cellular connection"
        case .processingFailed:
            return "Image processing failed"
        }
    }
}