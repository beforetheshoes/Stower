import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Rendered as the contents of a popover anchored to the Reader toolbar's Listen
// button. Kept in its own file to keep ReaderScreen type-check times under control.
struct ReaderListenControls: View {
    @Environment(\.flexokiPalette) private var palette
    let speech: ReaderSpeechFeature.State
    let speechBlocks: [SpeechBlock]
    let onListen: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void
    let onSkipBackward: () -> Void
    let onSkipForward: () -> Void
    let onRateChanged: (Float) -> Void
    let onVoiceChanged: (String?) -> Void

    @State private var catalog: ReaderSpeechVoiceCatalog.Catalog = ReaderSpeechVoiceCatalog.Catalog(
        preferredGroups: [],
        otherGroups: [],
        onlyDefaultQualityForPreferred: false
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            playbackRow
            speedSection
            voiceSection

            #if os(iOS)
            if catalog.onlyDefaultQualityForPreferred {
                downloadVoicesRow
            }
            #endif

            footerMessages
        }
        .task {
            catalog = ReaderSpeechVoiceCatalog.loadCatalog()
        }
    }

    // MARK: - Playback

    /// Whether the currently-speaking sentence is the first queued
    /// unit. Used to dim the skip-backward button so it doesn't pretend
    /// to do something it can't. Uses `sequence` rather than
    /// `blockIndex` because a single document block expands into many
    /// sentences that all share an index.
    private var isAtFirstBlock: Bool {
        guard let current = speech.currentSequence,
              let first = speech.currentBlocks.first?.sequence else {
            return true
        }
        return current <= first
    }

    /// Whether the currently-speaking sentence is the last queued unit.
    private var isAtLastBlock: Bool {
        guard let current = speech.currentSequence,
              let last = speech.currentBlocks.last?.sequence else {
            return true
        }
        return current >= last
    }

    @ViewBuilder
    private var playbackRow: some View {
        HStack(spacing: 10) {
            if speech.isSpeaking {
                Button(action: onSkipBackward) {
                    Image(systemName: "backward.fill")
                        .frame(minWidth: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isAtFirstBlock)
                .accessibilityLabel("Previous section")
                .help("Previous section")

                Button {
                    if speech.isPaused {
                        onResume()
                    } else {
                        onPause()
                    }
                } label: {
                    Label(
                        speech.isPaused ? "Resume" : "Pause",
                        systemImage: speech.isPaused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onSkipForward) {
                    Image(systemName: "forward.fill")
                        .frame(minWidth: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isAtLastBlock)
                .accessibilityLabel("Next section")
                .help("Next section")

                Button(role: .destructive) {
                    onStop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(minWidth: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel("Stop")
            } else {
                Button {
                    onListen()
                } label: {
                    Label("Listen", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(speechBlocks.isEmpty)
            }
        }
    }

    // MARK: - Speed

    private var speedBinding: Binding<Float> {
        Binding(
            get: { roundedSpeedBucket(for: speech.rate) },
            set: { onRateChanged($0) }
        )
    }

    @ViewBuilder
    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speed")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Speed", selection: speedBinding) {
                Text("0.8×").tag(Float(0.8))
                Text("1×").tag(Float(1.0))
                Text("1.2×").tag(Float(1.2))
                Text("1.5×").tag(Float(1.5))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Snap the feature's stored rate to one of the picker buckets so the
    /// segmented control always shows a selection even if older state held
    /// a value that's no longer in the bucket list.
    private func roundedSpeedBucket(for rate: Float) -> Float {
        let buckets: [Float] = [0.8, 1.0, 1.2, 1.5]
        return buckets.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1.0
    }

    // MARK: - Voice

    @ViewBuilder
    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Voice")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                voiceMenuContents
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                    Text(currentVoiceLabel)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var voiceMenuContents: some View {
        Button("Automatic") { onVoiceChanged(nil) }
        Divider()
        ForEach(catalog.preferredGroups) { group in
            voiceGroupMenu(group)
        }
        if !catalog.otherGroups.isEmpty {
            Menu("More languages") {
                ForEach(catalog.otherGroups) { group in
                    voiceGroupMenu(group)
                }
            }
        }
    }

    @ViewBuilder
    private func voiceGroupMenu(_ group: ReaderSpeechVoiceCatalog.LanguageGroup) -> some View {
        Menu(group.displayName) {
            ForEach(group.voices) { voice in
                Button(voice.displayName) { onVoiceChanged(voice.id) }
            }
        }
    }

    private var currentVoiceLabel: String {
        guard let id = speech.selectedVoiceID else { return "Automatic" }
        let all = catalog.preferredGroups.flatMap(\.voices) + catalog.otherGroups.flatMap(\.voices)
        return all.first(where: { $0.id == id })?.displayName ?? "Automatic"
    }

    // MARK: - Download voices footer

    #if os(iOS)
    @ViewBuilder
    private var downloadVoicesRow: some View {
        Button {
            openVoiceSettings()
        } label: {
            Label("Download better voices…", systemImage: "arrow.down.circle")
                .font(.footnote)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    private func openVoiceSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
    #endif

    // MARK: - Footer messages

    @ViewBuilder
    private var footerMessages: some View {
        if let error = speech.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(palette.error)
        } else if speechBlocks.isEmpty {
            Text("No readable text found.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
