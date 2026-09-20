import Foundation
import SwiftSoup

/// The parts of an EPUB's package document (`.opf`) that book import needs:
/// descriptive metadata, the manifest, and the reading order.
struct EPUBBookPackage: Equatable, Sendable {
    struct ManifestItem: Equatable, Sendable {
        var id: String
        /// Path inside the zip, already resolved against the OPF's directory.
        var path: String
        var mediaType: String
        var properties: Set<String>
    }

    var title: String?
    var author: String?
    var publisher: String?
    var summary: String?
    var publishedAt: Date?
    var manifest: [ManifestItem]
    /// Manifest items in reading order. Non-linear items (`linear="no"`) and
    /// the navigation document are left out.
    var spine: [ManifestItem]
    /// Path of the cover image inside the zip, when the package declares one.
    var coverImagePath: String?
    /// Path of the EPUB 3 navigation document, when present.
    var navigationPath: String?
    /// Path of the EPUB 2 NCX table of contents, when present.
    var ncxPath: String?
}

enum EPUBPackageParser {
    /// Reads `META-INF/container.xml` and returns the zip path of the package
    /// document it points at.
    static func packagePath(containerXML: String) throws -> String? {
        let document = try SwiftSoup.parse(containerXML, "", Parser.xmlParser())
        for rootfile in elements(named: "rootfile", in: document) {
            let path = try rootfile.attr("full-path").trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return path
            }
        }
        return nil
    }

    static func parse(opfXML: String, opfPath: String) throws -> EPUBBookPackage {
        let document = try SwiftSoup.parse(opfXML, "", Parser.xmlParser())

        var manifest = [EPUBBookPackage.ManifestItem]()
        for item in elements(named: "item", in: document) {
            let id = try item.attr("id")
            let href = try item.attr("href")
            guard !id.isEmpty, let path = EPUBPath.resolve(href, relativeTo: opfPath) else { continue }
            let properties = try item.attr("properties")
                .split(separator: " ")
                .map(String.init)
            manifest.append(
                EPUBBookPackage.ManifestItem(
                    id: id,
                    path: path,
                    mediaType: try item.attr("media-type").lowercased(),
                    properties: Set(properties)
                )
            )
        }
        let manifestByID = Dictionary(manifest.map { ($0.id, $0) }) { first, _ in first }

        let navigation = manifest.first { $0.properties.contains("nav") }
        var spine = [EPUBBookPackage.ManifestItem]()
        for itemref in elements(named: "itemref", in: document) {
            guard try itemref.attr("linear").lowercased() != "no",
                  let item = manifestByID[try itemref.attr("idref")],
                  item.id != navigation?.id,
                  item.mediaType.contains("html") || item.mediaType.contains("xml")
            else { continue }
            spine.append(item)
        }

        var coverImagePath = manifest.first { $0.properties.contains("cover-image") }?.path
        if coverImagePath == nil {
            // EPUB 2: `<meta name="cover" content="{manifest id}">`.
            for meta in elements(named: "meta", in: document) where try meta.attr("name") == "cover" {
                coverImagePath = manifestByID[try meta.attr("content")]?.path
                break
            }
        }

        let ncxID = try elements(named: "spine", in: document).first?.attr("toc") ?? ""
        let ncxPath = manifestByID[ncxID]?.path
            ?? manifest.first { $0.mediaType == "application/x-dtbncx+xml" }?.path

        return EPUBBookPackage(
            title: try firstText(named: "dc:title", in: document),
            author: try firstText(named: "dc:creator", in: document),
            publisher: try firstText(named: "dc:publisher", in: document),
            summary: try firstText(named: "dc:description", in: document),
            publishedAt: try firstText(named: "dc:date", in: document).flatMap(parseDate),
            manifest: manifest,
            spine: spine,
            coverImagePath: coverImagePath,
            navigationPath: navigation?.path,
            ncxPath: ncxPath
        )
    }

    /// Chapter labels from an EPUB 3 navigation document, keyed by the zip
    /// path of the content document each entry points at. The first label
    /// for a document wins, so a chapter with sub-sections keeps its own name.
    static func navigationLabels(navXHTML: String, navPath: String) throws -> [String: String] {
        let document = try SwiftSoup.parse(navXHTML)
        let tocLinks = try document.select("nav[epub:type=toc] a[href], nav#toc a[href]")
        let links = tocLinks.isEmpty() ? try document.select("nav a[href]") : tocLinks
        var labels = [String: String]()
        for link in links.array() {
            let label = cleanText(try link.text())
            guard !label.isEmpty,
                  let path = EPUBPath.resolve(try link.attr("href"), relativeTo: navPath),
                  labels[path] == nil
            else { continue }
            labels[path] = label
        }
        return labels
    }

    /// Chapter labels from an EPUB 2 NCX document, keyed like `navigationLabels`.
    static func ncxLabels(ncxXML: String, ncxPath: String) throws -> [String: String] {
        let document = try SwiftSoup.parse(ncxXML, "", Parser.xmlParser())
        var labels = [String: String]()
        for navPoint in elements(named: "navPoint", in: document) {
            guard let content = elements(named: "content", in: navPoint).first,
                  let labelElement = elements(named: "navLabel", in: navPoint).first,
                  let path = EPUBPath.resolve(try content.attr("src"), relativeTo: ncxPath),
                  labels[path] == nil
            else { continue }
            let label = cleanText(try labelElement.text())
            if !label.isEmpty {
                labels[path] = label
            }
        }
        return labels
    }

    /// True when `META-INF/encryption.xml` encrypts anything other than
    /// fonts. Font obfuscation is part of the EPUB specification and leaves
    /// the text readable; any other algorithm means the content is locked.
    static func hasEncryptedContent(encryptionXML: String) throws -> Bool {
        let fontObfuscation = [
            "http://www.idpf.org/2008/embedding",
            "http://ns.adobe.com/pdf/enc#RC",
        ]
        let document = try SwiftSoup.parse(encryptionXML, "", Parser.xmlParser())
        for method in elements(named: "EncryptionMethod", in: document) {
            let algorithm = try method.attr("Algorithm")
            if !fontObfuscation.contains(algorithm) {
                return true
            }
        }
        return false
    }

    // MARK: - Helpers

    /// Elements whose tag matches `name`, with or without a namespace prefix.
    /// OPF and NCX files use prefixes inconsistently (`opf:item`, `item`), so
    /// matching on the local name handles both.
    private static func elements(named name: String, in root: Element) -> [Element] {
        let wanted = name.lowercased()
        let wantedLocal = wanted.split(separator: ":").last.map(String.init) ?? wanted
        let all = (try? root.getAllElements().array()) ?? []
        return all.filter { element in
            let tag = element.tagName().lowercased()
            if tag == wanted {
                return true
            }
            guard !wanted.contains(":") else { return false }
            return tag.split(separator: ":").last.map(String.init) == wantedLocal
        }
    }

    private static func firstText(named name: String, in root: Element) throws -> String? {
        for element in elements(named: name, in: root) {
            let text = cleanText(try element.text())
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = try? Date(trimmed, strategy: .iso8601) {
            return date
        }
        // `2014-05-01`, `2014-05` and `2014` are all valid `dc:date` values.
        let parts = trimmed.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard let year = parts.first, (1...9999).contains(year) else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = year
        components.month = parts.count > 1 ? parts[1] : 1
        components.day = parts.count > 2 ? parts[2] : 1
        return components.date
    }
}

/// Path arithmetic for hrefs inside an EPUB zip.
enum EPUBPath {
    /// Resolves `href` against the zip path of the document that contains it
    /// and returns a normalized zip path with no fragment, query, or
    /// percent-encoding. Returns nil for absolute URLs (`https:`, `data:`)
    /// and for hrefs that escape the archive root.
    static func resolve(_ href: String, relativeTo documentPath: String) -> String? {
        var reference = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fragment = reference.firstIndex(of: "#") {
            reference = String(reference[..<fragment])
        }
        if let query = reference.firstIndex(of: "?") {
            reference = String(reference[..<query])
        }
        guard !reference.isEmpty else { return nil }
        if let colon = reference.firstIndex(of: ":"),
           !reference[..<colon].contains("/") {
            return nil
        }
        let decoded = reference.removingPercentEncoding ?? reference

        var segments = [Substring]()
        if !decoded.hasPrefix("/") {
            segments = Array(documentPath.split(separator: "/", omittingEmptySubsequences: true).dropLast())
        }
        for segment in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                guard !segments.isEmpty else { return nil }
                segments.removeLast()
            default:
                segments.append(segment)
            }
        }
        return segments.isEmpty ? nil : segments.joined(separator: "/")
    }
}
