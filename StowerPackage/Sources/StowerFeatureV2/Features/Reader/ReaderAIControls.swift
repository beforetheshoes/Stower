import ComposableArchitecture
import StowerData
import SwiftUI

/// Popover contents for the reader's AI tools. Two tabs via a segmented
/// `Picker`:
///
///   • **Summary** — generates (or re-generates) a cached summary for the
///     current article. Shows streaming snapshots as the model produces them.
///   • **Ask** — chat-style Q&A scoped to the current article. Ephemeral:
///     the transcript lives in reducer state and is cleared when the popover
///     is dismissed (via `cancelAll`) or the reader navigates away.
///
/// When Apple Intelligence isn't available on the device, the body is replaced
/// with a per-reason explanation instead of the tabs.
struct ReaderAIControls: View {
    @Bindable var store: StoreOf<ReaderAIFeature>
    @Environment(\.flexokiPalette) private var palette
    let document: ReaderDocument?
    let plainText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .padding(16)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Picker("Mode", selection: $store.mode.sending(\.modeChanged)) {
                Text("Summary").tag(ReaderAIFeature.State.Mode.summary)
                Text("Ask").tag(ReaderAIFeature.State.Mode.ask)
            }
            .pickerStyle(.segmented)
            .disabled(store.availability != .available)
        }
        .padding(12)
    }

    // MARK: - Content routing

    @ViewBuilder
    private var content: some View {
        switch store.availability {
        case .available:
            switch store.mode {
            case .summary:
                summaryTab
            case .ask:
                askTab
            }
        case .appleIntelligenceNotEnabled:
            unavailableCard(
                title: "Apple Intelligence is off",
                message: "Turn on Apple Intelligence in Settings to use Summary and Ask."
            )
        case .deviceNotEligible:
            unavailableCard(
                title: "Not supported",
                message: "This device doesn't support Apple Intelligence. Summary and Ask require a newer device."
            )
        case .modelNotReady:
            unavailableCard(
                title: "Preparing model",
                message: "Apple Intelligence is still getting ready. Try again in a minute."
            )
        case .other(let message):
            unavailableCard(
                title: "AI features unavailable",
                message: message
            )
        }
    }

    @ViewBuilder
    private func unavailableCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary tab

    @ViewBuilder
    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.summaryText.isEmpty {
                ScrollView {
                    Text(store.summaryText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)

                HStack {
                    summaryFootnote
                    Spacer()
                    Button {
                        store.send(.summarizeRequested(document: document, plainText: plainText))
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isSummarizing)
                }
            } else if store.isSummarizing {
                VStack(spacing: 12) {
                    ProgressView()
                    if let stage = store.summaryStage {
                        Text(stage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Generating summary…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Generate an on-device AI summary of this article.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        store.send(.summarizeRequested(document: document, plainText: plainText))
                    } label: {
                        Label("Summarize this article", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(plainText.isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = store.summaryError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var summaryFootnote: some View {
        if store.summaryWasCached, let date = store.summaryGeneratedAt {
            Text("Cached \(relativeDateText(date))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if store.summaryGeneratedAt != nil {
            Text("Just now")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            EmptyView()
        }
    }

    private func relativeDateText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date.now)
    }

    // MARK: - Ask tab

    @ViewBuilder
    private var askTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.transcript.isEmpty && store.pendingAnswer.isEmpty && !store.isAnswering {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ask a question about this article.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Answers come from the article text only. The model will say so if the answer isn't in the article.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.transcript) { entry in
                            transcriptEntry(question: entry.question, answer: entry.answer, isPending: false)
                        }
                        if store.isAnswering {
                            transcriptEntry(
                                question: store.question.trimmingCharacters(in: .whitespacesAndNewlines),
                                answer: store.pendingAnswer,
                                isPending: true
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let error = store.askError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField(
                    "Ask about this article",
                    text: $store.question.sending(\.questionChanged),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .disabled(store.isAnswering)
                .onSubmit(submitQuestion)

                Button {
                    submitQuestion()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isAnswering || store.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plainText.isEmpty)
            }
        }
    }

    private func submitQuestion() {
        store.send(.askSubmitted(document: document, plainText: plainText))
    }

    @ViewBuilder
    private func transcriptEntry(question: String, answer: String, isPending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !question.isEmpty {
                Text(question)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            if isPending && answer.isEmpty && store.isRetrieving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Searching the article…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if isPending && answer.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(answer)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        // Liquid Glass chat-bubble. Refracts the popover's background
        // so the transcript feels like floating cards instead of the
        // old flat grey fill.
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }
}
