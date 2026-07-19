import SwiftUI

/// One engine's result card in the stacked list: collapsible header with
/// status and retry, streaming body (or inline error), speak/copy footer.
struct ResultCardView: View {
    @ObservedObject var engineRun: EngineRunModel
    @ObservedObject private var speech = SpeechService.shared
    @Binding var isCollapsed: Bool
    /// Presentation of the per-run performance popover (LLM engines). Owned by
    /// the view model so a page-mode switch can dismiss it before the resize.
    @Binding var metricsPresented: Bool
    /// BCP-47 code of the run's target language, for voice selection.
    var targetLanguage: String?
    /// Ceiling for this card's stable body viewport. Passed in so the viewport
    /// can shrink when several providers share the window (keeping every header
    /// visible); overflow scrolls internally via TextKit 2.
    var maxBodyHeight: CGFloat
    var onRetry: () -> Void
    /// Apple language-pack download, invoked from the in-card prompt.
    var onDownloadApple: (String?, String) -> Void

    /// Minimum viewport reserved as soon as the card appears — comfortably
    /// fits the "翻译中…" placeholder and a first line so a fresh or short
    /// result never looks collapsed.
    private static let minBodyHeight: CGFloat = PanelLayout.lineAlignedBodyHeight(atMost: 44)

    /// Tracks the stream's natural content height so the body grows with it;
    /// growth is throttled (see `StreamingTextView`) and capped at
    /// `bodyCeiling`, past which the body scrolls internally instead of
    /// resizing the card further.
    @State private var contentHeight: CGFloat = Self.minBodyHeight

    /// `maxBodyHeight` snapped to a whole line so the body never stops
    /// mid-line at the cap.
    private var bodyCeiling: CGFloat {
        PanelLayout.lineAlignedBodyHeight(atMost: maxBodyHeight)
    }

    private var displayedBodyHeight: CGFloat {
        // While the "翻译中…" placeholder is up (a fresh or re-run translation
        // with no body yet), stay at the compact minimum regardless of a tracked
        // height left over from a previous result. A card is reused across runs
        // (SwiftUI keys it by the stable engine id), so `contentHeight` @State
        // survives into the next translation; without this the placeholder would
        // inherit the prior result's height and open tall.
        if isAwaitingContent { return Self.minBodyHeight }
        return min(max(contentHeight, Self.minBodyHeight), bodyCeiling)
    }

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
                    // Always mounted at a stable height. Streaming changes only
                    // the text storage; it never changes the card/window layout.
                    StreamingTextView(
                        model: engineRun.stream,
                        heightCeiling: bodyCeiling,
                        onContentHeightChange: { contentHeight = $0 }
                    )
                        .frame(height: displayedBodyHeight)
                        .overlay(alignment: .topLeading) {
                            if isAwaitingContent {
                                // Match the streamed text exactly — same 14pt size and
                                // the NSTextView's 10/8 inset — so when the first chunk
                                // replaces this placeholder the glyphs don't shift size
                                // or position. Only the content (and its color) changes,
                                // so the swap reads as a clean replacement instead of a
                                // flicker where the text jumps as it turns white.
                                Text("翻译中…")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                            }
                        }
                    Divider().padding(.horizontal, 10)
                    footer
                }
            }
        }
        // A soft shadow lifts each card off the glass panel so the results read
        // as distinct surfaces stacked above the chrome, not shapes blended into
        // the same translucent background.
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.thinMaterial)
                .shadow(color: .black.opacity(0.16), radius: 5, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.18))
        )
        // Entering the awaiting/placeholder state (a new run on a reused card)
        // drops the leftover height so, when the first chunk lands, the body
        // grows from the compact minimum instead of flashing the prior result's
        // height for a frame before the stream re-measures.
        .onChange(of: isAwaitingContent) { _, awaiting in
            if awaiting { contentHeight = Self.minBodyHeight }
        }
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
                    // Per-engine mark before the name, so the provider reads at a
                    // glance without relying on the (user-editable) text label.
                    EngineIcon(kind: engineRun.kind)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .center)
                    // Metadata, not content: kept in the secondary color so the
                    // translation body below is the only prominent (label-color)
                    // text in the card — clear primary/secondary hierarchy.
                    Text(engineRun.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    statusGlyph
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Per-run performance readout (LLM engines only): first-token
            // latency + throughput. Click opens a compact popover; tucked right
            // after the name so it reads as provider metadata, not an action.
            if engineRun.kind.isLLM, let metrics = engineRun.metrics {
                Button {
                    metricsPresented.toggle()
                } label: {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.caption)
                        .foregroundStyle(metricsPresented ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("翻译性能")
                .accessibilityIdentifier("result.metrics")
                .accessibilityValue(metrics.tooltip)
                // Publish this gauge's position (only while its readout is open)
                // so PanelRootView can float the card right beside it.
                .anchorPreference(key: MetricsAnchorKey.self, value: .bounds) {
                    metricsPresented ? $0 : nil
                }
            }

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
