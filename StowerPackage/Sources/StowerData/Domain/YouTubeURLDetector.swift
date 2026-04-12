import Foundation

/// Pure URL-parsing helper that recognizes YouTube video URLs in their various
/// shapes and returns the canonical 11-character video ID along with the form
/// of the original link (watch page, short URL, shorts, embed).
///
/// The detector lives in `StowerData` because it's dependency-free Foundation
/// code that both the ingestion pipeline (in `StowerFeatureV2`) and the reader
/// renderer call into. No regex — everything flows through `URLComponents`.
public enum YouTubeURLDetector {
    /// The structural form of the original link. The reader renderer uses this
    /// to pick between a 16:9 or 9:16 wrapper.
    public enum Form: String, Sendable, Equatable {
        case watch = "watch"
        case shortsVertical = "shortsVertical"
        case embed = "embed"
        case youtuBe = "youtuBe"
    }

    public struct Match: Sendable, Equatable {
        public let videoID: String
        public let form: Form

        public init(videoID: String, form: Form) {
            self.videoID = videoID
            self.form = form
        }
    }

    // MARK: - Public API

    /// Returns a match if `url` points at a recognizable YouTube video, nil otherwise.
    public static func match(_ url: URL) -> Match? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = normalizedHost(components.host) else {
            return nil
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }

        switch host {
        case "youtube.com", "youtube-nocookie.com":
            // /watch?v=ID
            if pathComponents.first == "watch" {
                if let v = components.queryItems?.first(where: { $0.name == "v" })?.value,
                   isValidVideoID(v) {
                    return Match(videoID: v, form: .watch)
                }
                return nil
            }
            // /shorts/ID
            if pathComponents.first == "shorts", pathComponents.count >= 2 {
                let id = pathComponents[1]
                return isValidVideoID(id) ? Match(videoID: id, form: .shortsVertical) : nil
            }
            // /embed/ID or /v/ID
            if pathComponents.first == "embed" || pathComponents.first == "v",
               pathComponents.count >= 2 {
                let id = pathComponents[1]
                return isValidVideoID(id) ? Match(videoID: id, form: .embed) : nil
            }
            return nil

        case "youtu.be":
            // youtu.be/ID
            guard let id = pathComponents.first, isValidVideoID(id) else { return nil }
            return Match(videoID: id, form: .youtuBe)

        default:
            return nil
        }
    }

    /// Convenience wrapper returning just the video ID.
    public static func videoID(from url: URL) -> String? {
        match(url)?.videoID
    }

    /// Returns true if `id` is a syntactically valid YouTube video ID
    /// (exactly 11 characters from `[A-Za-z0-9_-]`). Re-used as a
    /// defense-in-depth guard at render time before the ID is interpolated
    /// into an iframe `src`.
    public static func isValidVideoID(_ id: String) -> Bool {
        guard id.count == 11 else { return false }
        for scalar in id.unicodeScalars {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-":
                continue
            default:
                return false
            }
        }
        return true
    }

    /// The canonical watch URL for a given video ID.
    /// Used as the `url` parameter when querying YouTube's oEmbed endpoint.
    public static func canonicalWatchURL(forID id: String) -> URL {
        URL(string: "https://www.youtube.com/watch?v=\(id)")!
    }

    /// The privacy-enhanced embed URL for a given video ID.
    /// Used as the iframe `src` at render time.
    public static func embedURL(forID id: String) -> URL {
        URL(string: "https://www.youtube-nocookie.com/embed/\(id)")!
    }

    /// A best-effort fallback thumbnail URL used when oEmbed fails to return
    /// `thumbnail_url`. `hqdefault.jpg` is the most widely available variant.
    public static func fallbackThumbnailURL(forID id: String) -> URL {
        URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!
    }

    // MARK: - Private helpers

    /// Strips a leading `www.` or `m.` from a host and lowercases it.
    /// Returns nil for an empty host.
    private static func normalizedHost(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        } else if host.hasPrefix("m.") {
            host.removeFirst(2)
        }
        return host
    }
}
