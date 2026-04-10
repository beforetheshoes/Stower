import AVFoundation
import SwiftUI

// Isolated into its own file to keep ReaderScreen type-check times under control.
struct ReaderListenControls: View {
    let speech: ReaderSpeechFeature.State
    let speechBlocks: [SpeechBlock]
    let onListen: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void
    let onRateChanged: (Float) -> Void
    let onVoiceChanged: (String?) -> Void
    let surfaceColor: Color
    let secondaryTextColor: Color

    private struct VoiceOption: Identifiable, Equatable {
        var id: String
        var title: String
        var voiceID: String
    }

    private var voiceOptions: [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
            .map { voice in
                VoiceOption(
                    id: voice.identifier,
                    title: "\(voice.name) (\(voice.language))",
                    voiceID: voice.identifier
                )
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                playbackButtons

                Menu {
                    Button("0.8x") { onRateChanged(0.8) }
                    Button("1.0x") { onRateChanged(1.0) }
                    Button("1.2x") { onRateChanged(1.2) }
                } label: {
                    Label("Speed", systemImage: "speedometer")
                }

                Menu {
                    Button("Default") { onVoiceChanged(nil) }
                    Divider()
                    ForEach(voiceOptions) { option in
                        Button(option.title) { onVoiceChanged(option.voiceID) }
                    }
                } label: {
                    Label("Voice", systemImage: "waveform")
                }

                Spacer()
            }

            if let error = speech.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if speechBlocks.isEmpty {
                Text("No readable text found.")
                    .font(.caption)
                    .foregroundStyle(secondaryTextColor)
            }
        }
        .padding(12)
        .background(surfaceColor, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var playbackButtons: some View {
        if speech.isSpeaking {
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
            }
            .buttonStyle(.borderedProminent)

            Button {
                onStop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
        } else {
            Button {
                onListen()
            } label: {
                Label("Listen", systemImage: "speaker.wave.2.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(speechBlocks.isEmpty)
        }
    }
}
