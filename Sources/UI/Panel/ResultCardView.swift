import SwiftUI

/// One engine's result card in the stacked list: collapsible header with
/// status and retry, streaming body (or inline error), speak/copy footer.
struct ResultCardView: View {
    @ObservedObject var engineRun: EngineRunModel
    @ObservedObject private var speech = SpeechService.shared
    @Binding var isCollapsed: Bool
    /// BCP-47 code of the run's target language, for voice selection.
    var targetLanguage: String?
    var onRetry: () -> Void

    @State private var textHeight: CGFloat = 44

    private static let minBodyHeight: CGFloat = 44
    private static let maxBodyHeight: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                if case .failed(let message) = engineRun.state {
                    errorBody(message)
                } else {
                    if engineRun.hasThinking {
                        thinkingSection
                        Divider().padding(.horizontal, 10)
                    }
                    StreamingTextView(
                        model: engineRun.stream,
                        onContentHeightChange: { textHeight = $0 }
                    )
                    .frame(height: min(max(textHeight + 16, Self.minBodyHeight), Self.maxBodyHeight))
                    footer
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isCollapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(engineRun.name)
                        .font(.caption.weight(.medium))
                    statusGlyph
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("重试此引擎")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch engineRun.state {
        case .streaming:
            ProgressView()
                .controlSize(.mini)
        case .done(let seconds):
            Text(String(format: "%.1fs", seconds))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
        }
    }

    private func errorBody(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                speech.toggle(
                    id: engineRun.id,
                    text: engineRun.stream.fullText,
                    languageCode: targetLanguage
                )
            } label: {
                Image(systemName: speech.speakingID == engineRun.id ? "stop.fill" : "speaker.wave.2")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(speech.speakingID == engineRun.id ? "停止朗读" : "朗读译文")

            Button {
                let text = engineRun.stream.fullText
                guard !text.isEmpty else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("复制译文")

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 7)
    }

    @ViewBuilder
    private var thinkingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                engineRun.thinkingExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: engineRun.thinkingExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("思考过程")
                        .font(.caption)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if engineRun.thinkingExpanded {
                StreamingTextView(model: engineRun.thinkingStream, fontSize: 12)
                    .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 160)
                    .opacity(0.75)
            }
        }
    }
}
