import Foundation

/// Downloads all assets referenced by an HTML page (JS modules, CSS, images, fonts)
/// and stores them on disk for fully offline WebView rendering.
///
/// The archive is stored at `Documents/StowerArchive/{itemID}/` with the original
/// URL path structure preserved, so a WKURLSchemeHandler can serve them.
enum AssetArchiver {
    /// Archives all assets referenced by the HTML page.
    /// Returns the set of archived file paths relative to the archive root.
    @discardableResult
    static func archiveAssets(
        html: String,
        baseURL: URL,
        itemID: UUID,
        session: URLSession = .shared
    ) async -> Set<String> {
        let archiveDir = archiveDirectory(for: itemID)
        try? FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        // Step 1: Find all asset URLs referenced in the HTML
        let discoveredURLs = discoverURLs(in: html, baseURL: baseURL)

        // Step 2: Fetch and save all discovered assets, scanning JS files for transitive imports
        var archived: Set<String> = []
        var fetched: Set<String> = []  // URLs we've already processed
        var toFetch = discoveredURLs

        // Iterate up to 3 levels of transitive imports
        for _ in 0..<3 {
            guard !toFetch.isEmpty else { break }

            let newAssets = await fetchAndSave(
                urls: toFetch,
                baseURL: baseURL,
                archiveDir: archiveDir,
                session: session
            )

            fetched.formUnion(toFetch.map(\.absoluteString))
            archived.formUnion(newAssets.map(\.relativePath))

            // Scan fetched JS and CSS files for transitive asset references.
            // Use each file's own URL as base so relative imports resolve correctly.
            var nextLevel: Set<URL> = []

            // JS: scan for import/export/dynamic import references
            let jsAssets = newAssets.filter { $0.relativePath.hasSuffix(".js") }
            for asset in jsAssets {
                let filePath = archiveDir.appendingPathComponent(asset.relativePath)
                if let jsContent = try? String(contentsOf: filePath, encoding: .utf8) {
                    let jsFileURL = URL(string: "/" + asset.relativePath, relativeTo: baseURL)?.absoluteURL ?? baseURL
                    let imports = discoverJSImports(in: jsContent, baseURL: jsFileURL)
                    for importURL in imports where !fetched.contains(importURL.absoluteString) {
                        nextLevel.insert(importURL)
                    }
                }
            }

            // CSS: scan for url() references (fonts, images, etc.)
            let cssAssets = newAssets.filter { $0.relativePath.hasSuffix(".css") }
            for asset in cssAssets {
                let filePath = archiveDir.appendingPathComponent(asset.relativePath)
                if let cssContent = try? String(contentsOf: filePath, encoding: .utf8) {
                    let cssFileURL = URL(string: "/" + asset.relativePath, relativeTo: baseURL)?.absoluteURL ?? baseURL
                    let refs = discoverCSSURLs(in: cssContent, baseURL: cssFileURL)
                    for refURL in refs where !fetched.contains(refURL.absoluteString) {
                        nextLevel.insert(refURL)
                    }
                }
            }

            toFetch = Array(nextLevel)
        }

        // Step 3: Save the raw HTML as source.html (unpatched, for future re-patching)
        let sourcePath = archiveDir.appendingPathComponent("source.html")
        try? html.write(to: sourcePath, atomically: true, encoding: .utf8)

        // Step 4: Persist archive metadata (origin URL) so the local server
        // can fetch-through missing assets on later loads, even without the
        // caller passing the origin in explicitly.
        saveMetadata(origin: baseURL, for: itemID)

        // Step 5: Patch the HTML for offline rendering and save as index.html
        let patchedHTML = Self.patchHTMLForOffline(html)
        let indexPath = archiveDir.appendingPathComponent("index.html")
        try? patchedHTML.write(to: indexPath, atomically: true, encoding: .utf8)

        return archived
    }

    // MARK: - Archive metadata sidecar

    /// Metadata sidecar stored alongside the archive so the server knows where
    /// to fetch-through missing assets on subsequent loads.
    private struct ArchiveMetadata: Codable {
        var origin: String
    }

    private static let metadataFilename = "archive-meta.json"

    /// Persists the origin URL for an archive so `LocalArchiveServer` can
    /// fetch-through missing assets.
    static func saveMetadata(origin: URL, for itemID: UUID) {
        let dir = archiveDirectory(for: itemID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let metaPath = dir.appendingPathComponent(metadataFilename)
        let meta = ArchiveMetadata(origin: origin.absoluteString)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaPath)
        }
    }

    /// Reads the persisted origin URL for an archive, if present.
    static func loadOriginURL(for itemID: UUID) -> URL? {
        let metaPath = archiveDirectory(for: itemID).appendingPathComponent(metadataFilename)
        guard let data = try? Data(contentsOf: metaPath),
              let meta = try? JSONDecoder().decode(ArchiveMetadata.self, from: data),
              let url = URL(string: meta.origin)
        else { return nil }
        return url
    }

    /// Returns the archive directory for a given item.
    static func archiveDirectory(for itemID: UUID) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs
            .appendingPathComponent("StowerArchive", isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
    }

    /// Checks whether an archive exists for the given item.
    static func archiveExists(for itemID: UUID) -> Bool {
        let dir = archiveDirectory(for: itemID)
        let indexPath = dir.appendingPathComponent("index.html")
        return FileManager.default.fileExists(atPath: indexPath.path)
    }

    /// Re-generates index.html from the original source HTML using the current patching logic.
    /// Call this before loading an archive to ensure the latest patches are applied.
    ///
    /// Tries sources in order:
    /// 1. `sourceHTML` parameter (raw HTML from the database)
    /// 2. `source.html` file in the archive directory
    /// If neither is available, falls back to leaving the existing index.html untouched.
    static func refreshIndexHTML(for itemID: UUID, sourceHTML: String? = nil) {
        let dir = archiveDirectory(for: itemID)
        let sourcePath = dir.appendingPathComponent("source.html")
        let indexPath = dir.appendingPathComponent("index.html")

        let rawHTML: String
        if let sourceHTML, !sourceHTML.isEmpty {
            rawHTML = sourceHTML
            // Also persist source.html for future refreshes
            try? sourceHTML.write(to: sourcePath, atomically: true, encoding: .utf8)
        } else if let stored = try? String(contentsOf: sourcePath, encoding: .utf8) {
            rawHTML = stored
        } else {
            return // No source available — legacy archive
        }

        let patched = patchHTMLForOffline(rawHTML)
        try? patched.write(to: indexPath, atomically: true, encoding: .utf8)
    }

    /// Strips any `<style id="stower-reader-css">` block that a previous
    /// version of the app may have baked into `index.html`. Left in place as
    /// a one-time cleanup for archives created before the overlay CSS was
    /// removed; new archives don't need it. Safe to call unconditionally.
    static func stripLegacyInjectedCSS(for itemID: UUID) {
        let indexPath = archiveDirectory(for: itemID).appendingPathComponent("index.html")
        guard var html = try? String(contentsOf: indexPath, encoding: .utf8),
              let existingStart = html.range(of: "<style id=\"stower-reader-css\">"),
              let existingEnd = html[existingStart.lowerBound...].range(of: "</style>")
        else { return }
        html.removeSubrange(existingStart.lowerBound..<existingEnd.upperBound)
        try? html.write(to: indexPath, atomically: true, encoding: .utf8)
    }

    /// Deletes the archive for a given item.
    static func deleteArchive(for itemID: UUID) {
        let dir = archiveDirectory(for: itemID)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - HTML Patching for Offline

    /// Patches HTML to work correctly when loaded offline via a local HTTP server.
    /// Handles React Router SSR apps that expect server-side features.
    static func patchHTMLForOffline(_ html: String) -> String {
        var result = html

        // Patch 1: Disable React Router's lazy route discovery.
        // When mode is "lazy", the client fetches /__manifest to discover routes at runtime.
        // Change to "initial" so it uses only the routes already in the inline manifest.
        result = result.replacingOccurrences(
            of: #""routeDiscovery":{"mode":"lazy""#,
            with: #""routeDiscovery":{"mode":"initial""#
        )

        // Patch 2: Strip CSP nonce attributes from script/style tags.
        // Without a matching CSP header from the local server, nonces would block execution.
        if let nonceRegex = try? NSRegularExpression(pattern: #"\s+nonce="[^"]*""#) {
            let range = NSRange(result.startIndex..., in: result)
            result = nonceRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        return result
    }

    // MARK: - URL Discovery

    /// Discovers all asset URLs referenced in the HTML.
    private static func discoverURLs(in html: String, baseURL: URL) -> [URL] {
        var urls: Set<URL> = []

        // Unescape JSON-encoded forward slashes (\/) so that paths like
        // "\/blog-assets\/build\/file.js" become "/blog-assets/build/file.js"
        // and are matched by the URL patterns below.
        let normalized = html.replacingOccurrences(of: "\\/", with: "/")

        // Match paths to common asset types. Captures group 1 = the URL/path.
        let patterns = [
            // Absolute paths to assets (starting with /)
            #"["'\(](/[^"'\s\)]+\.(?:js|css|woff2?|ttf|otf|eot|png|jpe?g|gif|webp|avif|svg|ico))["'\s\)]"#,
            // Relative paths to assets (starting with ../ or ./)
            #"["'\(](\.\.?/[^"'\s\)]+\.(?:js|css|woff2?|ttf|otf|eot|png|jpe?g|gif|webp|avif|svg|ico))["'\s\)]"#,
            // Full URLs to assets (with file extension)
            #"["'\(](https?://[^"'\s\)]+\.(?:js|css|woff2?|ttf|otf|eot|png|jpe?g|gif|webp|avif|svg|ico))["'\s\)]"#,
            // Google Fonts CSS (has query params, no file extension)
            #"["'\(](https?://fonts\.googleapis\.com/css[^"'\s\)]*)["'\s\)]"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
            for match in matches {
                if let range = Range(match.range(at: 1), in: normalized) {
                    let ref = String(normalized[range])
                    if let resolved = URL(string: ref, relativeTo: baseURL) {
                        urls.insert(resolved)
                    }
                }
            }
        }

        return Array(urls)
    }

    /// Discovers import URLs in JavaScript source code.
    private static func discoverJSImports(in jsContent: String, baseURL: URL) -> [URL] {
        var urls: Set<URL> = []

        // Unescape JSON-encoded forward slashes for bundled JS that may contain
        // manifest data or dynamic import paths with escaped slashes.
        let normalized = jsContent.replacingOccurrences(of: "\\/", with: "/")

        // Match: import ... from "/path/file.js"
        // Match: import("/path/file.js") and import(`./file.js`) (backtick templates)
        // Match: "/path/file.js" or "relative/path/file.js" in deps arrays
        let patterns = [
            #"(?:import|export)\s+.*?from\s*["']([^"']+\.js)["']"#,
            #"import\s*\(\s*["'`]([^"'`]+\.js)["'`]\s*\)"#,
            // Any quoted/backtick-delimited string containing a "/" and ending in .js or .css
            // Catches absolute paths (/build/file.js), relative (./file.js),
            // and bare relative paths (blog-assets/build/file.js) in Vite dep maps.
            #"["'`]([^"'`\s]*?/[^"'`\s]*?\.(?:js|css))["'`]"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
            for match in matches {
                if let range = Range(match.range(at: 1), in: normalized) {
                    var ref = String(normalized[range])

                    // Bare relative paths like "blog-assets/build/file.js" from Vite
                    // dep maps are root-relative but missing the leading "/".
                    if !ref.hasPrefix("/") && !ref.hasPrefix("./") &&
                       !ref.hasPrefix("../") && !ref.hasPrefix("http") {
                        ref = "/" + ref
                    }

                    if let resolved = URL(string: ref, relativeTo: baseURL) {
                        urls.insert(resolved)
                    }
                }
            }
        }

        return Array(urls)
    }

    /// Discovers asset URLs referenced via `url()` in CSS content (fonts, images, etc.).
    private static func discoverCSSURLs(in cssContent: String, baseURL: URL) -> [URL] {
        var urls: Set<URL> = []

        // Match: url("path/to/font.woff2") or url('../image.png') or url(path)
        let pattern = #"url\(\s*["']?([^"'\)\s]+)["']?\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let matches = regex.matches(in: cssContent, range: NSRange(cssContent.startIndex..., in: cssContent))
        for match in matches {
            if let range = Range(match.range(at: 1), in: cssContent) {
                let ref = String(cssContent[range])
                // Skip data URIs and fragment-only references
                if ref.hasPrefix("data:") || ref.hasPrefix("#") { continue }
                if let resolved = URL(string: ref, relativeTo: baseURL) {
                    urls.insert(resolved)
                }
            }
        }

        return Array(urls)
    }

    // MARK: - Fetch & Save

    private struct ArchivedAsset {
        let relativePath: String
    }

    private static func fetchAndSave(
        urls: [URL],
        baseURL: URL,
        archiveDir: URL,
        session: URLSession
    ) async -> [ArchivedAsset] {
        await withTaskGroup(of: ArchivedAsset?.self, returning: [ArchivedAsset].self) { group in
            for url in urls {
                group.addTask {
                    await fetchAndSaveOne(url: url, baseURL: baseURL, archiveDir: archiveDir, session: session)
                }
            }
            // swiftlint:disable:next prefer_let_over_var
            var results: [ArchivedAsset] = []
            for await asset in group {
                if let asset { results.append(asset) }
            }
            return results
        }
    }

    private static func fetchAndSaveOne(
        url: URL,
        baseURL: URL,
        archiveDir: URL,
        session: URLSession
    ) async -> ArchivedAsset? {
        // For same-origin assets, use the URL path directly.
        // For cross-origin assets, namespace under _ext/{host}/ to avoid collisions.
        let urlHost = url.host(percentEncoded: false)
        let baseHost = baseURL.host(percentEncoded: false)
        let pathPart = String(url.path.dropFirst()) // e.g. "assets/stylesheets/main.css"

        let localPath: String
        if let urlHost, let baseHost, urlHost != baseHost {
            // Cross-origin: namespace by host
            let safePath = pathPart.isEmpty ? "index" : pathPart
            localPath = "_ext/\(urlHost)/\(safePath)"
        } else {
            localPath = pathPart
        }
        guard !localPath.isEmpty else { return nil }

        let localFile = archiveDir.appendingPathComponent(localPath)

        // Skip if already downloaded
        if FileManager.default.fileExists(atPath: localFile.path) {
            return ArchivedAsset(relativePath: localPath)
        }

        // Fetch
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  data.count < 20_000_000 else { // 20MB limit per file
                return nil
            }

            // Create parent directories
            let parent = localFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

            // Write to disk
            try data.write(to: localFile)
            return ArchivedAsset(relativePath: localPath)
        } catch {
            return nil
        }
    }
}
