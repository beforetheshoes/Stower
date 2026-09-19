import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Rendered as the contents of a popover anchored to the Reader toolbar's Listen
// button. Kept in its own file to keep ReaderScreen type-check times under control.
struct ReaderListenControls: View {
    @Environment(\.flexokiPalette)
    private var palette
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            playbackRow
            speedSection
            voiceSection

            if speech.isPreparingVoice {
                preparingVoiceRow
            }

            footerMessages
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

    @ViewBuilder private var playbackRow: some View {
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
                // Liquid Glass prominent button — matches system media
                // transport controls where a single play/pause button is
                // the primary control surrounded by secondary transport.
                .buttonStyle(.glassProminent)
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
                // Liquid Glass prominent — the single starting action for TTS.
                .buttonStyle(.glassProminent)
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

    @ViewBuilder private var speedSection: some View {
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
        return buckets.min { abs($0 - rate) < abs($1 - rate) } ?? 1.0
    }

    // MARK: - Voice

    @ViewBuilder private var voiceSection: some View {
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
                        .accessibilityLabel("Voice")
                    Text(currentVoiceLabel)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
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

    @ViewBuilder private var voiceMenuContents: some View {
        ForEach(ReaderSpeechVoice.allCases) { voice in
            Button {
                onVoiceChanged(voice.rawValue)
            } label: {
                if voice == speech.voice {
                    Label(voice.displayName, systemImage: "checkmark")
                } else {
                    Text(voice.displayName)
                }
            }
        }
    }

    private var currentVoiceLabel: String {
        speech.voice.displayName
    }

    // MARK: - Preparing voice

    /// Shown while the voice model downloads (first use) or loads into memory.
    @ViewBuilder private var preparingVoiceRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Preparing voice…")
                    .font(.footnote.weight(.medium))
                Text("The first time, this downloads about 100 MB. After that it works offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Footer messages

    @ViewBuilder private var footerMessages: some View {
        if let error = speech.errorMessage {
            CopyableText(text: error, textColor: palette.error)
        } else if speechBlocks.isEmpty {
            Text("No readable text found.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
