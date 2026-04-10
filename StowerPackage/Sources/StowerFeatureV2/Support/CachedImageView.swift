import SwiftUI

/// A URLSession-backed image loader that uses a shared disk cache.
/// Replaces AsyncImage for reader figures so images survive offline use.
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

    func load(url: URL) {
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
                #if canImport(UIKit)
                if let uiImage = UIImage(data: data) {
                    await MainActor.run { self?.phase = .success(Image(uiImage: uiImage)) }
                } else {
                    await MainActor.run { self?.phase = .failure(URLError(.cannotDecodeContentData)) }
                }
                #elseif canImport(AppKit)
                if let nsImage = NSImage(data: data) {
                    await MainActor.run { self?.phase = .success(Image(nsImage: nsImage)) }
                } else {
                    await MainActor.run { self?.phase = .failure(URLError(.cannotDecodeContentData)) }
                }
                #endif
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.phase = .failure(error) }
            }
        }
    }

    deinit {
        loadTask?.cancel()
    }
}

/// Drop-in replacement for AsyncImage that uses a persistent disk cache.
struct CachedImageView<Content: View>: View {
    let url: URL
    @ViewBuilder let content: (ImageLoader.Phase) -> Content

    @State private var loader = ImageLoader()

    var body: some View {
        content(loader.phase)
            .task(id: url) {
                loader.load(url: url)
            }
    }
}
