import Foundation
import OSLog
import ZIPFoundation

private let kUnpackerLog = Logger(
    subsystem: "com.ryanleewilliams.stower",
    category: "WebsiteArchiveUnpacker"
)

/// Unpacks a user-supplied `.zip` containing a static website into the given
/// archive directory. Produces the same on-disk layout the reader already
/// understands (`index.html` + sibling assets at the archive root), so the
/// existing `.webView` + `LocalArchiveServer` path renders the site without
/// any reader-side changes.
///
/// Security properties:
///   * Rejects the whole archive if any entry would write outside the
///     destination directory after path resolution (Zip Slip defense).
///   * Skips symlinks entirely — the archive is served by
///     `LocalArchiveServer` via absolute file paths, so symlink semantics
///     are not needed and would only widen the attack surface.
///   * Caps cumulative uncompressed bytes so a zip bomb can't exhaust disk
///     or memory before being aborted.
enum WebsiteArchiveUnpacker {
    struct UnpackResult {
        let indexURL: URL
        let title: String?
        /// Archive-relative POSIX path to a hero image resolved from the
        /// unpacked index (e.g. `"images/cover.jpg"`). Nil when no usable
        /// candidate is found. Callers that want a URL for this image should
        /// prefix with `stower-archive:` for sync storage, or resolve against
        /// `AssetArchiver.archiveDirectory(for:)` for local rendering.
        let heroImageRelativePath: String?
        let entryCount: Int
        let uncompressedBytes: Int64
    }

    /// Scheme prefix used by the library thumbnail resolver to route a
    /// hero-image reference back to a file on disk. The remainder of the URL
    /// is a path relative to the item's archive root, so the same value
    /// syncs across devices without pinning to any single device's Documents
    /// directory.
    static let heroArchiveURLScheme = "stower-archive"

    enum UnpackError: Error, LocalizedError, CustomStringConvertible {
        case cannotOpenArchive
        case pathTraversal(String)
        case uncompressedSizeExceeded(Int64)
        case noIndexHTML
        case writeFailed(entryPath: String, underlying: Error)

        var description: String {
            switch self {
            case .cannotOpenArchive:
                return "The zip file could not be opened. It may be corrupt or password-protected."
            case .pathTraversal(let path):
                return "The zip contains an unsafe entry path (\(path)). Import aborted."
            case .uncompressedSizeExceeded(let cap):
                return "The zip's contents exceed the \(cap / 1_048_576) MB uncompressed limit."
            case .noIndexHTML:
                return "The zip does not contain an index.html at its root or one folder deep."
            case .writeFailed(let entryPath, let underlying):
                return "Failed to unpack \"\(entryPath)\": \(underlying.localizedDescription)"
            }
        }

        var errorDescription: String? { description }
    }

    /// Unpacks `zipURL` into `destination`, which must be an empty directory
    /// (or a path that does not yet exist). On any error, the destination is
    /// removed so the caller sees a clean slate.
    ///
    /// - Parameters:
    ///   - zipURL: Local file URL of the zip to unpack.
    ///   - destination: Target directory for the archive root. Will be
    ///     created if missing and wiped on any failure.
    ///   - maxUncompressedBytes: Hard ceiling on total uncompressed bytes.
    ///     Typical values: 400 MB for a 200 MB compressed cap.
    static func unpack(
        zipAt zipURL: URL,
        into destination: URL,
        maxUncompressedBytes: Int64 = 400 * 1_048_576
    ) throws -> UnpackResult {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw UnpackError.cannotOpenArchive
        }

        var uncompressedTotal: Int64 = 0
        var entryCount = 0

        var currentEntryPath = ""
        do {
            for entry in archive {
                currentEntryPath = entry.path

                // Skip macOS Finder "Compress" metadata — these entries are
                // never needed by the site itself and often have quirky paths
                // (AppleDouble `._` files, nested `__MACOSX/` mirrors) that
                // can trip extraction on case-sensitive or sandboxed volumes.
                if entry.path.hasPrefix("__MACOSX/")
                    || entry.path.split(separator: "/").last?.hasPrefix("._") == true {
                    continue
                }

                // Traversal defense: the only ways a zip entry can write
                // outside `destination` are via `..` segments or an
                // absolute path. Reject both here before we touch the
                // filesystem. String-based prefix comparisons against
                // `standardizedFileURL.path` aren't reliable — macOS and
                // iOS resolve `/var` ↔ `/private/var` symlinks
                // inconsistently depending on whether the URL points at an
                // existing path, so a check that passes on one platform
                // flags a legitimate `guide/` entry on the other.
                let segments = entry.path.split(separator: "/", omittingEmptySubsequences: true)
                if entry.path.hasPrefix("/") || segments.contains(where: { $0 == ".." }) {
                    throw UnpackError.pathTraversal(entry.path)
                }
                let resolvedURL = resolvedEntryURL(entry: entry.path, in: destination)

                switch entry.type {
                case .directory:
                    try fileManager.createDirectory(
                        at: resolvedURL,
                        withIntermediateDirectories: true
                    )
                case .symlink:
                    // Silently skipped. Logged for post-mortems.
                    kUnpackerLog.info("Skipping symlink entry: \(entry.path, privacy: .public)")
                case .file:
                    let projectedSize = uncompressedTotal + Int64(entry.uncompressedSize)
                    if projectedSize > maxUncompressedBytes {
                        throw UnpackError.uncompressedSizeExceeded(maxUncompressedBytes)
                    }
                    try fileManager.createDirectory(
                        at: resolvedURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    _ = try archive.extract(entry, to: resolvedURL)
                    uncompressedTotal += Int64(entry.uncompressedSize)
                    entryCount += 1
                }
            }
        } catch let error as UnpackError {
            try? fileManager.removeItem(at: destination)
            throw error
        } catch {
            kUnpackerLog.error(
                "Unpack failed on entry \(currentEntryPath, privacy: .public): \(String(reflecting: error), privacy: .public)"
            )
            try? fileManager.removeItem(at: destination)
            throw UnpackError.writeFailed(entryPath: currentEntryPath, underlying: error)
        }

        // Resolve the entry point without moving files around. The reader
        // serves the archive directly through `LocalArchiveServer`, so a
        // nested `guide/index.html` is loaded from `http://localhost/guide/`
        // and the HTML's own relative paths (including `../sibling/...`
        // references) resolve against that base URL exactly the way they
        // did in the browser the author tested in.
        let indexURL: URL
        do {
            indexURL = try locateIndex(in: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        let title = extractTitle(from: indexURL)
        let heroRelativePath = extractHeroImageRelativePath(
            indexURL: indexURL,
            archiveRoot: destination
        )

        return UnpackResult(
            indexURL: indexURL,
            title: title,
            heroImageRelativePath: heroRelativePath,
            entryCount: entryCount,
            uncompressedBytes: uncompressedTotal
        )
    }

    /// Scans the given index HTML for a hero image and returns its path
    /// relative to `archiveRoot`. Only references that resolve to a file
    /// already unpacked inside the archive are returned — absolute `https://`
    /// URLs, protocol-relative `//…` URLs, and `data:` URIs are skipped
    /// because they defeat the whole point of offline archival.
    ///
    /// Detection order:
    ///   1. `<meta property="og:image">`
    ///   2. `<meta name="twitter:image">`
    ///   3. `<link rel="apple-touch-icon">` (usually 180×180)
    ///   4. First `<img>` tag's `src`
    static func extractHeroImageRelativePath(
        indexURL: URL,
        archiveRoot: URL
    ) -> String? {
        guard let html = try? String(contentsOf: indexURL, encoding: .utf8) else {
            return nil
        }
        return extractHeroImageRelativePath(
            fromHTML: html,
            indexURL: indexURL,
            archiveRoot: archiveRoot
        )
    }

    /// Pure-string variant exposed for testing. `indexURL` is used as the
    /// base when resolving relative `src`/`content` values, so it should
    /// point at where the HTML lives inside `archiveRoot`.
    static func extractHeroImageRelativePath(
        fromHTML html: String,
        indexURL: URL,
        archiveRoot: URL
    ) -> String? {
        let scrubbed = stripSVGBlocks(in: html)
        let candidates: [String?] = [
            firstMatch(
                in: scrubbed,
                pattern: #"<meta[^>]+property\s*=\s*["']og:image["'][^>]*content\s*=\s*["']([^"']+)["'][^>]*>"#
            ),
            firstMatch(
                in: scrubbed,
                pattern: #"<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]*property\s*=\s*["']og:image["'][^>]*>"#
            ),
            firstMatch(
                in: scrubbed,
                pattern: #"<meta[^>]+name\s*=\s*["']twitter:image["'][^>]*content\s*=\s*["']([^"']+)["'][^>]*>"#
            ),
            firstMatch(
                in: scrubbed,
                pattern: #"<link[^>]+rel\s*=\s*["']apple-touch-icon["'][^>]*href\s*=\s*["']([^"']+)["'][^>]*>"#
            ),
            firstMatch(
                in: scrubbed,
                pattern: #"<img[^>]+src\s*=\s*["']([^"']+)["'][^>]*>"#
            ),
        ]

        for candidate in candidates {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { continue }

            // Reject anything that can't resolve to a local file.
            if raw.hasPrefix("data:") { continue }
            if raw.hasPrefix("//") { continue }
            if raw.lowercased().hasPrefix("http://") { continue }
            if raw.lowercased().hasPrefix("https://") { continue }

            // Drop any query/fragment — they're irrelevant for file lookup
            // and often carry cache-busting hashes that would never match
            // what's actually on disk.
            let withoutQuery = raw
                .components(separatedBy: "?").first ?? raw
            let pathOnly = withoutQuery
                .components(separatedBy: "#").first ?? withoutQuery

            let resolved = URL(
                fileURLWithPath: pathOnly,
                relativeTo: indexURL
            ).standardizedFileURL

            let rootPath = archiveRoot.standardizedFileURL.path
            guard
                resolved.path == rootPath
                    || resolved.path.hasPrefix(rootPath + "/"),
                FileManager.default.fileExists(atPath: resolved.path)
            else { continue }

            let relative = String(resolved.path.dropFirst(rootPath.count + 1))
            if relative.isEmpty { continue }
            return relative
        }

        return nil
    }

    /// Finds the archive's entry HTML. Returns whichever of
    /// `index.html`/`index.htm` sits at the root, or — failing that — the
    /// shallowest match in a breadth-first walk up to `maxSearchDepth`
    /// levels. The on-disk layout is left unchanged; callers that need to
    /// serve the archive over HTTP use `relativePath(of:in:)` to derive the
    /// URL path the reader should load.
    ///
    /// Nested entries are common in zips exported by authoring tools (a
    /// single top-level "site" folder) and in zips whose HTML uses
    /// `../sibling/...` references — promoting would silently break those
    /// references, so we keep the tree intact and let the archive server
    /// serve whatever the file's own paths already work against.
    /// Public lookup used by the reader to discover where the archive's
    /// entry HTML actually lives on disk. Returns the nested or root
    /// `index.html`/`index.htm`, or nil if the archive doesn't contain one.
    static func findEntryURL(in root: URL) -> URL? {
        try? locateIndex(in: root)
    }

    private static func locateIndex(in root: URL) throws -> URL {
        let fileManager = FileManager.default
        let rootIndex = root.appendingPathComponent("index.html")
        if fileManager.fileExists(atPath: rootIndex.path) {
            return rootIndex
        }
        let rootIndexHTM = root.appendingPathComponent("index.htm")
        if fileManager.fileExists(atPath: rootIndexHTM.path) {
            return rootIndexHTM
        }

        guard let found = breadthFirstSearchIndex(in: root, maxDepth: 4) else {
            throw UnpackError.noIndexHTML
        }
        return found
    }

    /// Builds the absolute URL for a zip entry by appending each POSIX path
    /// segment one at a time. Single-argument `appendingPathComponent` has
    /// historically had subtle differences between platforms around how
    /// multi-segment strings (`"a/b/c"`), trailing slashes, and embedded
    /// slashes are handled — some platforms percent-encode the slash, some
    /// split on it, some preserve a trailing `/` in `.path`, some don't.
    /// Walking segment-by-segment sidesteps all of that.
    static func resolvedEntryURL(entry path: String, in destination: URL) -> URL {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        var url = destination
        for segment in segments {
            url = url.appendingPathComponent(String(segment))
        }
        return url
    }

    /// POSIX-style path of `url` relative to `root` (e.g., `"guide/index.html"`).
    /// Returns nil if `url` does not live inside `root`. Exposed so the reader
    /// can build the URL path to load from `LocalArchiveServer`.
    static func relativePath(of url: URL, in root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        guard urlPath.hasPrefix(rootPath + "/") else { return nil }
        return String(urlPath.dropFirst(rootPath.count + 1))
    }

    /// Breadth-first walk for the shallowest `index.html`/`index.htm` inside
    /// `root`. Returns the file URL or nil if none is found within `maxDepth`
    /// directory levels.
    private static func breadthFirstSearchIndex(in root: URL, maxDepth: Int) -> URL? {
        let fileManager = FileManager.default
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            let children = (try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            // Files first at this level — any `index.html`/`index.htm` wins.
            for child in children {
                let name = child.lastPathComponent.lowercased()
                if name == "index.html" || name == "index.htm" {
                    let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if !isDir { return child }
                }
            }

            if depth >= maxDepth { continue }

            for child in children {
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { queue.append((child, depth + 1)) }
            }
        }
        return nil
    }

    /// Extracts a human-readable title from the given HTML file. Tries, in
    /// order: `<head><title>`, `<meta property="og:title">`, the first
    /// `<h1>`. `<svg><title>` blocks and any tag nested inside `<svg>…</svg>`
    /// are ignored so accent icon titles don't win. Returns nil if none of
    /// these resolve to non-empty text.
    static func extractTitle(from indexURL: URL) -> String? {
        guard
            let html = try? String(contentsOf: indexURL, encoding: .utf8)
        else {
            return nil
        }
        return extractTitle(fromHTML: html)
    }

    /// Pure-string variant of `extractTitle(from:)` — exposed for testing and
    /// for callers that have the HTML already loaded.
    static func extractTitle(fromHTML html: String) -> String? {
        // Strip <svg>…</svg> blocks first so their nested <title> tags never
        // masquerade as the page title. Regexes over HTML are a known trap;
        // for this narrow purpose a single-level strip is sufficient.
        let scrubbed = stripSVGBlocks(in: html)

        if let title = firstMatch(
            in: scrubbed,
            pattern: #"<title[^>]*>([\s\S]*?)</title>"#
        ) {
            return clean(title)
        }

        if let ogTitle = firstMatch(
            in: scrubbed,
            pattern: #"<meta[^>]+property\s*=\s*["']og:title["'][^>]*content\s*=\s*["']([^"']+)["'][^>]*>"#
        ) ?? firstMatch(
            in: scrubbed,
            pattern: #"<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]*property\s*=\s*["']og:title["'][^>]*>"#
        ) {
            return clean(ogTitle)
        }

        if let h1 = firstMatch(
            in: scrubbed,
            pattern: #"<h1[^>]*>([\s\S]*?)</h1>"#
        ) {
            // Strip any HTML tags inside the <h1> before cleaning so things
            // like `<h1><span>Title</span></h1>` don't bleed markup into the
            // library card.
            let stripped = h1.replacingOccurrences(
                of: #"<[^>]+>"#,
                with: "",
                options: .regularExpression
            )
            return clean(stripped)
        }

        return nil
    }

    private static func firstMatch(in html: String, pattern: String) -> String? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(
                in: html,
                range: NSRange(html.startIndex..., in: html)
            ),
            match.numberOfRanges >= 2,
            let range = Range(match.range(at: 1), in: html)
        else {
            return nil
        }
        return String(html[range])
    }

    private static func stripSVGBlocks(in html: String) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"<svg[\s\S]*?</svg>"#,
                options: [.caseInsensitive]
            )
        else { return html }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(
            in: html,
            range: range,
            withTemplate: ""
        )
    }

    private static func clean(_ raw: String) -> String? {
        let unescaped = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        // Collapse runs of whitespace (common in multi-line <h1>s).
        let collapsed = unescaped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
