import SwiftUI

/// One engine's result card in the stacked list: collapsible header with
/// status and retry, streaming body (or inline error), speak/copy footer.
struct ResultCardView: View {
    @ObservedObject var engineRun: EngineRunModel
    @ObservedObject private var speech = SpeechService.shared
    @Binding var isCollapsed: Bool
    /// BCP-47 code of the run's target language, for voice selection.
    var targetLanguage: String?
    /// "Grow until here, then scroll" ceiling for this card's body. Passed in so
    /// it can shrink when several providers share the window (keeping every
    /// header visible); past it the body scrolls internally via TextKit 2.
    var maxBodyHeight: CGFloat
    var onRetry: () -> Void
    /// Apple language-pack download, invoked from the in-card prompt.
    var onDownloadApple: (String?, String) -> Void

    @State private var textHeight: CGFloat = 44

    private static let minBodyHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                switch engineRun.state {
                case .failed(let message):
                    errorBody(message)
                case .needsAppleDownload(let source, let target):
                    downloadBody(source: source, target: target)
                default:
                    if engineRun.hasThinking {
                        thinkingSection
                        Divider().padding(.horizontal, 10)
                    }
                    // Always mounted (even before the first chunk) so SwiftUI
                    // sizes it to the real width up front — measuring an empty
                    // buffer yields the minimum height, and text then streams in
                    // without a wrong-width height spike. A "翻译中…" overlay
                    // stands in until the first chunk lands.
                    StreamingTextView(
                        model: engineRun.stream,
                        onContentHeightChange: { textHeight = $0 }
                    )
                    // Before the first chunk, force the minimum height. This is
                    // independent of `textHeight`, so a stale measurement left
                    // over from the previous run (re-translate reuses the card)
                    // can't balloon the empty box — a known race in the height
                    // reset. Once content lands, the measured height takes over.
                    .frame(height: isAwaitingContent
                        ? Self.minBodyHeight
                        : PanelLayout.resolvedBodyHeight(
                            text: textHeight, min: Self.minBodyHeight, cap: maxBodyHeight))
                    .overlay(alignment: .topLeading) {
                        if isAwaitingContent {
                            Text("翻译中…")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                    }
                    Divider().padding(.horizontal, 10)
                    footer
                }
            }
        }
        .onChange(of: isAwaitingContent) { _, awaiting in
            // A fresh run reuses this card; drop the previous run's measured
            // height so streaming grows from the minimum instead of spiking to
            // the old (possibly maximal) value before the new text is measured.
            if awaiting { textHeight = Self.minBodyHeight }
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
                // Toggle instantly: an animated height change fires many
                // intermediate geometry updates, each nudging the window resize
                // and making the input above visibly jitter. One clean resize.
                isCollapsed.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10, alignment: .center)
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
        case .needsAppleDownload:
            Image(systemName: "arrow.down.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Streaming but no body text yet — show the "翻译中…" placeholder overlay.
    private var isAwaitingContent: Bool {
        if case .streaming = engineRun.state { return !engineRun.hasContent }
        return false
    }

    private func downloadBody(source: String?, target: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("需要下载 \(LanguagePolicy.localizedName(for: target)) 语言包")
                    .font(.callout)
                Text("首次使用需下载，之后离线可用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button {
                onDownloadApple(source, target)
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
                    .frame(width: FooterIcon.width, height: FooterIcon.height)
            }
            .buttonStyle(.borderless)
            .help(speech.speakingID == engineRun.id ? "停止朗读" : "朗读译文")
            .accessibilityIdentifier("result.speak")

            CopyButton(text: engineRun.stream.fullText, help: "复制译文", identifier: "result.copy")

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
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
                        .frame(width: 10, alignment: .center)
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
