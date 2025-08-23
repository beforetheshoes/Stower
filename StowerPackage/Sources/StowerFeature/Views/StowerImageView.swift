import SwiftUI

public struct StowerImageView: View {
    let uuid: UUID
    let alt: String
    let maxHeight: CGFloat
    
    @State private var imageData: Data?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var showingFullScreen = false
    
    public init(uuid: UUID, alt: String = "", maxHeight: CGFloat = 400) {
        self.uuid = uuid
        self.alt = alt
        self.maxHeight = maxHeight
    }
    
    public var body: some View {
        Group {
            if let imageData = imageData {
                #if os(iOS)
                if let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: maxHeight)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                        .onTapGesture {
                            showingFullScreen = true
                        }
                        .accessibilityHint("Tap to view full size")
                } else {
                    fallbackView
                }
                #elseif os(macOS)
                if let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: maxHeight)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                        .onTapGesture {
                            showingFullScreen = true
                        }
                        .accessibilityHint("Tap to view full size")
                } else {
                    fallbackView
                }
                #endif
            } else if isLoading {
                loadingView
            } else {
                fallbackView
            }
        }
        .task {
            await loadImage()
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingFullScreen) {
            if let imageData = imageData {
                FullScreenImageViewer(imageData: imageData, alt: alt)
            }
        }
        #elseif os(macOS)
        .sheet(isPresented: $showingFullScreen) {
            if let imageData = imageData {
                MacOSImageViewer(imageData: imageData, alt: alt)
            }
        }
        #endif
    }
    
    @ViewBuilder
    private var loadingView: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.gray.opacity(0.1))
            .frame(height: min(maxHeight, 100))
            .overlay {
                ProgressView()
                    .scaleEffect(0.8)
            }
            .accessibilityLabel("Loading image")
    }
    
    @ViewBuilder
    private var fallbackView: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.gray.opacity(0.15))
            .frame(height: min(maxHeight, 60))
            .overlay {
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
                    .font(.title2)
            }
            .accessibilityLabel(alt.isEmpty ? "Image unavailable" : "\(alt) - unavailable")
    }
    
    @MainActor
    private func loadImage() async {
        guard imageData == nil else { return }
        
        isLoading = true
        loadFailed = false
        
        do {
            if let data = await ImageCacheService.shared.image(for: uuid) {
                imageData = data
                print("✅ StowerImageView: Loaded image \(uuid) (\(data.count) bytes)")
            } else {
                loadFailed = true
                print("❌ StowerImageView: Failed to load image \(uuid)")
            }
        }
        
        isLoading = false
    }
}

// MARK: - Convenience initializers for different size categories

extension StowerImageView {
    public static func small(uuid: UUID, alt: String = "") -> StowerImageView {
        StowerImageView(uuid: uuid, alt: alt, maxHeight: 24)
    }
    
    public static func medium(uuid: UUID, alt: String = "") -> StowerImageView {
        StowerImageView(uuid: uuid, alt: alt, maxHeight: 60)
    }
    
    public static func large(uuid: UUID, alt: String = "") -> StowerImageView {
        StowerImageView(uuid: uuid, alt: alt, maxHeight: 400)
    }
}

// MARK: - Full Screen Image Viewer

private struct FullScreenImageViewer: View {
    let imageData: Data
    let alt: String
    
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black
                    .ignoresSafeArea(.all)
                
                GeometryReader { geometry in
                    #if os(iOS)
                    if let uiImage = UIImage(data: imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(
                                SimultaneousGesture(
                                    MagnificationGesture()
                                        .onChanged { value in
                                            scale = lastScale * value
                                        }
                                        .onEnded { value in
                                            lastScale = scale
                                            // Limit zoom out
                                            if scale < 1.0 {
                                                withAnimation(.easeInOut) {
                                                    scale = 1.0
                                                    lastScale = 1.0
                                                    offset = .zero
                                                    lastOffset = .zero
                                                }
                                            }
                                            // Limit zoom in
                                            else if scale > 4.0 {
                                                withAnimation(.easeInOut) {
                                                    scale = 4.0
                                                    lastScale = 4.0
                                                }
                                            }
                                        },
                                    DragGesture()
                                        .onChanged { value in
                                            offset = CGSize(
                                                width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height
                                            )
                                        }
                                        .onEnded { value in
                                            lastOffset = offset
                                        }
                                )
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.easeInOut) {
                                    if scale > 1.0 {
                                        scale = 1.0
                                        lastScale = 1.0
                                        offset = .zero
                                        lastOffset = .zero
                                    } else {
                                        scale = 2.0
                                        lastScale = 2.0
                                    }
                                }
                            }
                    }
                    #elseif os(macOS)
                    if let nsImage = NSImage(data: imageData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(
                                SimultaneousGesture(
                                    MagnificationGesture()
                                        .onChanged { value in
                                            scale = lastScale * value
                                        }
                                        .onEnded { value in
                                            lastScale = scale
                                            // Limit zoom out
                                            if scale < 1.0 {
                                                withAnimation(.easeInOut) {
                                                    scale = 1.0
                                                    lastScale = 1.0
                                                    offset = .zero
                                                    lastOffset = .zero
                                                }
                                            }
                                            // Limit zoom in
                                            else if scale > 4.0 {
                                                withAnimation(.easeInOut) {
                                                    scale = 4.0
                                                    lastScale = 4.0
                                                }
                                            }
                                        },
                                    DragGesture()
                                        .onChanged { value in
                                            offset = CGSize(
                                                width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height
                                            )
                                        }
                                        .onEnded { value in
                                            lastOffset = offset
                                        }
                                )
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.easeInOut) {
                                    if scale > 1.0 {
                                        scale = 1.0
                                        lastScale = 1.0
                                        offset = .zero
                                        lastOffset = .zero
                                    } else {
                                        scale = 2.0
                                        lastScale = 2.0
                                    }
                                }
                            }
                    }
                    #endif
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            #elseif os(macOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.escape)
                    .buttonStyle(.borderedProminent)
                }
            }
            .toolbarBackground(.hidden, for: .windowToolbar)
            #endif
        }
        .accessibilityLabel(alt.isEmpty ? "Full screen image" : alt)
        .accessibilityHint("Double tap to zoom, drag to pan, pinch to zoom")
    }
}

// MARK: - macOS-Specific Image Viewer

#if os(macOS)
private struct MacOSImageViewer: View {
    let imageData: Data
    let alt: String
    
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.95)
                .ignoresSafeArea(.all)
            
            if let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = lastScale * value
                                }
                                .onEnded { value in
                                    lastScale = scale
                                    // Limit zoom out
                                    if scale < 1.0 {
                                        withAnimation(.easeInOut) {
                                            scale = 1.0
                                            lastScale = 1.0
                                            offset = .zero
                                            lastOffset = .zero
                                        }
                                    }
                                    // Limit zoom in
                                    else if scale > 4.0 {
                                        withAnimation(.easeInOut) {
                                            scale = 4.0
                                            lastScale = 4.0
                                        }
                                    }
                                },
                            DragGesture()
                                .onChanged { value in
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { value in
                                    lastOffset = offset
                                }
                        )
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut) {
                            if scale > 1.0 {
                                scale = 1.0
                                lastScale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2.0
                                lastScale = 2.0
                            }
                        }
                    }
            }
            
            // Close button overlay
            VStack {
                HStack {
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.escape)
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
                Spacer()
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .accessibilityLabel(alt.isEmpty ? "Full screen image" : alt)
        .accessibilityHint("Double click to zoom, drag to pan, scroll to zoom")
    }
}
#endif

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        StowerImageView.small(uuid: UUID(), alt: "Small icon")
        StowerImageView.medium(uuid: UUID(), alt: "Medium graphic")
        StowerImageView.large(uuid: UUID(), alt: "Large content image")
    }
    .padding()
}