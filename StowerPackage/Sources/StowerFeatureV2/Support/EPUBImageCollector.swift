import Foundation
import StowerData

/// One image the EPUB exporter should try to obtain. Requests are deduplicated
/// by `key`, so the same remote photo referenced twice ships once.
struct EPUBImageRequest: Hashable, Sendable {
    enum Role: Hashable, Sendable {
        case hero
        case figure
        case poster
    }

    /// Dedupe key. The media's `sourceURL` for figures (including the
    /// `stower://pdf-page/N` markers PDF ingestion emits), the hero URL for
    /// the cover, and the poster URL for provider videos.
    let key: String
    /// Path to an already-downloaded copy, when ingestion cached one.
    let localPath: String?
    /// Remote fallback. Only http(s) URLs qualify; everything else is nil.
    let remoteURL: URL?
    let declaredMIMEType: String?
    let role: Role
}

/// Walks a reader document and lists the images an export needs, hero first,
/// then in first-appearance order.
enum EPUBImageCollector {
    static func requests(item: SavedItem, document: ReaderDocument) -> [EPUBImageRequest] {
        var seen = Set<String>()
        var requests = [EPUBImageRequest]()

        func append(_ request: EPUBImageRequest) {
            guard seen.insert(request.key).inserted else { return }
            requests.append(request)
        }

        if let hero = heroRequest(item: item, document: document) {
            append(hero)
        }

        for block in document.blocks {
            switch block {
            case .figure(let media):
                append(figureRequest(media))

            case .video(let media):
                if let poster = posterRequest(media) {
                    append(poster)
                }

            case .paragraph, .heading, .list, .blockquote, .code, .embed, .table, .horizontalRule, .callout:
                continue
            }
        }

        return requests
    }

    /// The hero doubles as the EPUB cover. It is skipped for YouTube saves,
    /// whose first block is already the same thumbnail at full width.
    private static func heroRequest(item: SavedItem, document: ReaderDocument) -> EPUBImageRequest? {
        guard let hero = item.heroImageURL, !hero.isEmpty,
              ReaderDocumentHTMLBuilder.isSafeHTTPURL(hero),
              !isYouTubeDocument(document)
        else { return nil }
        return EPUBImageRequest(
            key: hero,
            localPath: nil,
            remoteURL: URL(string: hero),
            declaredMIMEType: nil,
            role: .hero
        )
    }

    private static func figureRequest(_ media: MediaDescriptor) -> EPUBImageRequest {
        EPUBImageRequest(
            key: media.sourceURL,
            localPath: media.localURL.flatMap { $0.isEmpty ? nil : $0 },
            remoteURL: ReaderDocumentHTMLBuilder.isSafeHTTPURL(media.sourceURL) ? URL(string: media.sourceURL) : nil,
            declaredMIMEType: media.mimeType,
            role: .figure
        )
    }

    private static func posterRequest(_ media: MediaDescriptor) -> EPUBImageRequest? {
        guard media.providerName == "YouTube",
              let id = media.providerVideoID,
              YouTubeURLDetector.isValidVideoID(id)
        else { return nil }
        let remote = media.posterURL.flatMap { ReaderDocumentHTMLBuilder.isSafeHTTPURL($0) ? $0 : nil }
        let local = media.posterLocalURL.flatMap { $0.isEmpty ? nil : $0 }
        guard remote != nil || local != nil else { return nil }
        return EPUBImageRequest(
            key: remote ?? "youtube-poster:\(id)",
            localPath: local,
            remoteURL: remote.flatMap(URL.init(string:)),
            declaredMIMEType: nil,
            role: .poster
        )
    }

    static func isYouTubeDocument(_ document: ReaderDocument) -> Bool {
        if case let .video(media) = document.blocks.first,
           media.providerName == "YouTube" {
            return true
        }
        return false
    }
}
