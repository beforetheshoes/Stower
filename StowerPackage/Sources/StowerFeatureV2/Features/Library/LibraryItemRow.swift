import SwiftUI

struct LibraryItemRow: View {
    let item: SavedItem
    let query: String
    let tags: [Tag]
    let displayStyle: LibraryDisplayStyle

    @Environment(\.flexokiPalette)
    private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !item.isRead {
                        Circle()
                            .fill(palette.primary)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }

                    Text(LibrarySearchHighlight.highlighted(item.title, query: query))
                        .font(.headline)
                        .foregroundStyle(item.isRead ? palette.tx2 : palette.tx)
                        .lineLimit(displayStyle == .compact ? 2 : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if item.isStarred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(palette.warning)
                            .accessibilityLabel("Starred")
                    }

                    processingIndicator
                }

                if !metadata.isEmpty {
                    Text(metadata.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                tagRow

                if displayStyle == .expanded {
                    if let excerpt = item.excerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(.subheadline)
                            .foregroundStyle(palette.tx2)
                            .lineLimit(3)
                    }

                    if let snippet = LibrarySearchHighlight.bodySnippet(item: item, query: query) {
                        Text(snippet)
                            .font(.subheadline)
                            .foregroundStyle(palette.tx2)
                            .lineLimit(2)
                    }
                }

                if let progress = item.libraryReadingProgress {
                    ProgressView(value: progress.fractionComplete)
                        .tint(palette.primary)
                        .accessibilityLabel("Reading progress")
                        .accessibilityValue("\(progress.percentComplete) percent")
                }
            }

            if let imageURL = resolvedImageURL {
                LibraryRowThumbnail(
                    url: imageURL,
                    size: displayStyle == .compact
                        ? CGSize(width: 64, height: 64)
                        : CGSize(width: 104, height: 84)
                )
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var metadata: [String] {
        var values = [String]()
        if let publication = item.siteName.flatMap({ $0.isEmpty ? nil : $0 }) ?? sourceHost {
            values.append(publication)
        }
        let date = item.publishedAt ?? item.createdAt
        values.append(date.formatted(date: .abbreviated, time: .omitted))
        if let minutes = item.readingTimeMinutes {
            values.append("\(minutes) min")
        }
        return values
    }

    private var sourceHost: String? {
        guard let sourceURL = item.sourceURL else { return nil }
        return URL(string: sourceURL)?.host ?? sourceURL
    }

    @ViewBuilder private var tagRow: some View {
        if !tags.isEmpty {
            let visible = Array(tags.prefix(3))
            HStack(spacing: 5) {
                ForEach(visible) { tag in
                    Text(tag.name)
                        .font(.caption)
                        .foregroundStyle(tagColor(tag.colorHex))
                }
                if tags.count > visible.count {
                    Text("+\(tags.count - visible.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }

    @ViewBuilder private var processingIndicator: some View {
        switch item.processingState {
        case .ready, .queued:
            EmptyView()
        case .extracting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Refreshing reader view"))
        case .partial:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(palette.warning)
                .accessibilityLabel("Partial capture")
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(palette.error)
                .accessibilityLabel("Capture failed")
        }
    }

    private var accessibilitySummary: String {
        var values = [item.title]
        if !item.isRead { values.append("Unread") }
        if item.isStarred { values.append("Starred") }
        values.append(contentsOf: metadata)
        if !tags.isEmpty {
            values.append("Tags: \(tags.map(\.name).joined(separator: ", "))")
        }
        return values.joined(separator: ", ")
    }

    private func tagColor(_ hex: String?) -> Color {
        guard let hex, !hex.isEmpty else { return palette.secondary }
        return Color(hex: hex)
    }

    private var resolvedImageURL: URL? {
        guard let hero = item.heroImageURL, !hero.isEmpty else { return nil }
        let archiveScheme = WebsiteArchiveUnpacker.heroArchiveURLScheme + ":"
        if hero.hasPrefix(archiveScheme) {
            let relative = String(hero.dropFirst(archiveScheme.count))
            guard !relative.isEmpty else { return nil }
            let url = AssetArchiver.archiveDirectory(for: item.id).appendingPathComponent(relative)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return URL(string: hero)
    }
}

private struct LibraryRowThumbnail: View {
    let url: URL
    let size: CGSize

    var body: some View {
        CachedImageView(url: url, targetPixelSize: max(size.width, size.height) * 4) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .failure:
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}
