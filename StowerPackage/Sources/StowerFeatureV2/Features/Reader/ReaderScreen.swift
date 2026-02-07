import AVKit
import ComposableArchitecture
import SwiftUI
import WebKit

public struct ReaderScreen: View {
    @Bindable var store: StoreOf<ReaderFeature>

    public init(store: StoreOf<ReaderFeature>) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let item = store.item {
                    ReaderHeader(item: item)

                    if let document = store.document {
                        ReaderDocumentView(
                            document: document,
                            openEmbed: { url in
                                store.send(.openInlineWebEmbed(url))
                            }
                        )
                    } else {
                        MarkdownContentView(markdown: item.content)
                    }

                    if item.processingState == .partial || item.processingState == .failed {
                        Button("Improve Formatting") {
                            store.send(.retryExtractionTapped)
                        }
                    }
                } else if store.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let error = store.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                } else {
                    Text("Item not found")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color.clear)
        .navigationTitle("Reader")
        .task { store.send(.load) }
        #if canImport(UIKit)
        .sheet(item: $store.scope(state: \.inlineEmbedURL, action: \.inlineEmbedURL)) { embedStore in
            NavigationStack {
                InlineEmbedScreen(store: embedStore)
            }
        }
        #endif
    }
}

private struct ReaderHeader: View {
    let item: SavedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title)
                .font(.system(.largeTitle, design: .serif, weight: .semibold))

            if let source = item.sourceURL, let sourceURL = URL(string: source) {
                Link(destination: sourceURL) {
                    Text(source)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                if let siteName = item.siteName {
                    Text(siteName)
                }
                if let minutes = item.readingTimeMinutes {
                    Text("\(minutes) min")
                }
                Text(item.processingState.rawValue.capitalized)
                    .foregroundStyle(statusStyle(item.processingState))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func statusStyle(_ state: ProcessingState) -> AnyShapeStyle {
        switch state {
        case .ready: return AnyShapeStyle(.green)
        case .partial: return AnyShapeStyle(.orange)
        case .failed: return AnyShapeStyle(.red)
        case .extracting: return AnyShapeStyle(.blue)
        case .queued: return AnyShapeStyle(.secondary)
        }
    }
}

private struct ReaderDocumentView: View {
    let document: ReaderDocument
    let openEmbed: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                ReaderBlockView(block: block, openEmbed: openEmbed)
            }
        }
        .textSelection(.enabled)
    }
}

private struct ReaderBlockView: View {
    let block: ReaderBlock
    let openEmbed: (String) -> Void

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            ReaderInlineText(inlines: inlines)
                .font(.system(size: 19, weight: .regular, design: .serif))
                .lineSpacing(8)

        case .heading(let level, let inlines):
            ReaderInlineText(inlines: inlines)
                .font(font(for: level))
                .padding(.top, level <= 2 ? 12 : 8)

        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.system(size: 18))
                        ReaderInlineText(inlines: item)
                            .font(.system(size: 18))
                    }
                }
            }

        case .blockquote(let inlines):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 4)
                    .clipShape(.rect(cornerRadius: 2))
                ReaderInlineText(inlines: inlines)
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
            }

        case .code(_, let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.thinMaterial, in: .rect(cornerRadius: 10))

        case .figure(let media):
            FigureView(media: media)
                .padding(.vertical, 10)

        case .video(let media):
            VideoBlockView(media: media)
                .padding(.vertical, 10)

        case .embed(let embed):
            EmbedCard(embed: embed, openEmbed: openEmbed)

        case .table(let markdown):
            MarkdownContentView(markdown: markdown)

        case .horizontalRule:
            Divider()

        case .callout(let title, let inlines):
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    Text(title)
                        .font(.headline)
                }
                ReaderInlineText(inlines: inlines)
                    .font(.body)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
        }
    }

    private func font(for level: Int) -> Font {
        switch level {
        case 1: return .system(size: 40, weight: .bold, design: .serif)
        case 2: return .system(size: 32, weight: .semibold, design: .serif)
        case 3: return .system(size: 26, weight: .semibold, design: .serif)
        default: return .system(size: 22, weight: .semibold, design: .serif)
        }
    }
}

private struct ReaderInlineText: View {
    let inlines: [ReaderInline]

    var body: some View {
        Text(attributedString)
    }

    private var attributedString: AttributedString {
        var output = AttributedString("")

        for inline in inlines {
            switch inline {
            case .text(let value):
                output += AttributedString(value + " ")
            case .link(let label, let url):
                var link = AttributedString(label + " ")
                link.link = URL(string: url)
                output += link
            case .emphasis(let value):
                var piece = AttributedString(value + " ")
                piece.inlinePresentationIntent = .emphasized
                output += piece
            case .strong(let value):
                var piece = AttributedString(value + " ")
                piece.inlinePresentationIntent = .stronglyEmphasized
                output += piece
            case .code(let value):
                var piece = AttributedString(value + " ")
                piece.inlinePresentationIntent = .code
                output += piece
            case .strikethrough(let value):
                var piece = AttributedString(value + " ")
                piece.strikethroughStyle = .single
                output += piece
            }
        }

        return output
    }
}

private struct FigureView: View {
    let media: MediaDescriptor

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            if let imageURL = URL(string: media.sourceURL) {
                AsyncImage(url: imageURL, transaction: .init(animation: .easeInOut)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 700, maxHeight: 460)
                            .clipShape(.rect(cornerRadius: 14))
                    case .failure:
                        if !isLikelyProfileImage(media) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.secondary.opacity(0.10))
                                .frame(maxWidth: 700, minHeight: 140, maxHeight: 180)
                        }
                    default:
                        ProgressView()
                            .frame(maxWidth: 700)
                            .frame(height: 180)
                    }
                }
            }

            if let caption = media.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func isLikelyProfileImage(_ media: MediaDescriptor) -> Bool {
        let combined = (media.sourceURL + " " + (media.altText ?? "") + " " + (media.caption ?? "")).lowercased()
        if ["avatar", "profile", "headshot", "gravatar", "author"].contains(where: combined.contains) {
            return true
        }
        if let width = media.width, let height = media.height, width <= 72, height <= 72 {
            return true
        }
        return false
    }
}

private struct VideoBlockView: View {
    let media: MediaDescriptor

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            if let url = URL(string: media.sourceURL) {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(maxWidth: 700, minHeight: 220, maxHeight: 420)
                    .clipShape(.rect(cornerRadius: 14))
            }
            if let caption = media.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct EmbedCard: View {
    let embed: EmbedDescriptor
    let openEmbed: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(embed.provider)
                .font(.headline)
            Text(embed.embedURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 10) {
                #if canImport(UIKit)
                Button("Open Inline") {
                    openEmbed(embed.embedURL)
                }
                #endif

                if let url = URL(string: embed.embedURL) {
                    Link("Open Source", destination: url)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: .rect(cornerRadius: 12))
    }
}

private struct InlineEmbedScreen: View {
    let store: StoreOf<InlineEmbedFeature>

    var body: some View {
        WebEmbedView(url: store.url)
            .navigationTitle("Embed")
    }
}

private struct WebEmbedView: View {
    let url: URL

    var body: some View {
        PlatformWebView(url: url)
            .ignoresSafeArea()
    }
}

#if canImport(UIKit)
private struct PlatformWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        return WKWebView(frame: .zero, configuration: config)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }
}
#elseif canImport(AppKit)
private struct PlatformWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        return WKWebView(frame: .zero, configuration: config)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url {
            nsView.load(URLRequest(url: url))
        }
    }
}
#endif

private struct MarkdownContentView: View {
    let markdown: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attributed)
                .textSelection(.enabled)
        } else {
            Text(markdown)
                .textSelection(.enabled)
        }
    }
}
