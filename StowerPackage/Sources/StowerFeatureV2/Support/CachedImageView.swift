import ImageIO
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A URLSession-backed image loader that uses a shared disk cache.
/// Replaces AsyncImage for reader figures so images survive offline use.
///
/// When `targetPixelSize` is set, the raw bytes are downsampled via
/// `CGImageSource` before being handed to SwiftUI. This is the only
/// correct way to render a 1200×630-style `og:image` into a small
/// thumbnail cell — SwiftUI's `.interpolation(.high)` modifier acts on
/// the drawing phase but can't undo the quality loss that happens when
/// the full-size bitmap is scaled to a tiny frame at render time.
@Observable
final class ImageLoader: @unchecked Sendable {
    enum Phase {
        case loading
        case success(Image)
        case failure(Error)
    }

    private(set) var phase: Phase = .loading

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    private static let session: URLSession = {
        let cache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,   // 32 MB in-memory
            diskCapacity: 256 * 1024 * 1024,     // 256 MB on disk
            diskPath: "StowerImageCache"
        )
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }()

    private var loadTask: Task<Void, Never>?

    /// Loads `url` into `phase`. If `targetPixelSize` is non-nil, the
    /// decoded image is thumbnailed to that max dimension via
    /// `CGImageSource` — the Apple-recommended path for high-quality,
    /// memory-efficient thumbnail rendering.
    func load(url: URL, targetPixelSize: CGFloat? = nil) {
        loadTask?.cancel()
        phase = .loading
        loadTask = Task { [weak self] in
            do {
                let data: Data
                if url.isFileURL {
                    data = try Data(contentsOf: url)
                } else {
                    let (downloaded, _) = try await Self.session.data(from: url)
                    data = downloaded
                }
                guard !Task.isCancelled else { return }

                let image = try Self.makeImage(from: data, targetPixelSize: targetPixelSize)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.phase = .success(image) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.phase = .failure(error) }
            }
        }
    }

    // MARK: - Decoding

    private static func makeImage(from data: Data, targetPixelSize: CGFloat?) throws -> Image {
        if let targetPixelSize, let cgImage = downsample(data: data, maxPixelSize: targetPixelSize) {
            return makeSwiftUIImage(cgImage: cgImage)
        }

        // Full-resolution path — used by the reader for figure images where
        // the display size can vary and downsampling would hurt quality.
        #if canImport(UIKit)
        if let uiImage = UIImage(data: data) {
            return Image(uiImage: uiImage)
        }
        #elseif canImport(AppKit)
        if let nsImage = NSImage(data: data) {
            return Image(nsImage: nsImage)
        }
        #endif
        throw URLError(.cannotDecodeContentData)
    }

    /// `CGImageSourceCreateThumbnailAtIndex` with the
    /// `kCGImageSourceCreateThumbnailFromImageAlways` flag performs a
    /// single high-quality downsample during decode, avoiding the need
    /// to decode the full image into memory first.
    private static func downsample(data: Data, maxPixelSize: CGFloat) -> CGImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        // swiftlint:disable collection_alignment
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        // swiftlint:enable collection_alignment
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    private static func makeSwiftUIImage(cgImage: CGImage) -> Image {
        #if canImport(UIKit)
        let uiImage = UIImage(cgImage: cgImage)
        return Image(uiImage: uiImage)
        #elseif canImport(AppKit)
        // NSImage with a CGImage honors the CGImage's natural pixel size.
        // Passing `.zero` tells AppKit to use it unchanged, which is what
        // we want since the downsample already produced the target size.
        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        return Image(nsImage: nsImage)
        #endif
    }

    deinit {
        loadTask?.cancel()
    }
}

/// Drop-in replacement for AsyncImage that uses a persistent disk cache.
///
/// Set `targetPixelSize` for thumbnail usage — the loader will downsample
/// at decode time rather than asking SwiftUI to scale a full-size bitmap.
/// Leave it nil for full-resolution display (e.g. reader figures).
struct CachedImageView<Content: View>: View {
    let url: URL
    var targetPixelSize: CGFloat?
    @ViewBuilder let content: (ImageLoader.Phase) -> Content

    @State private var loader = ImageLoader()

    init(
        url: URL,
        targetPixelSize: CGFloat? = nil,
        @ViewBuilder content: @escaping (ImageLoader.Phase) -> Content
    ) {
        self.url = url
        self.targetPixelSize = targetPixelSize
        self.content = content
    }

    var body: some View {
        content(loader.phase)
            .task(id: url) {
                loader.load(url: url, targetPixelSize: targetPixelSize)
            }
    }
}
