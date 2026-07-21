import SwiftUI

/// Bob-style panel layout: toolbar on top, input editor, language bar in the
/// middle, stacked engine result cards below.
struct PanelRootView: View {
    @ObservedObject var viewModel: PanelViewModel
    @ObservedObject var run: TranslationRunController
    /// Includes the mode that produced the measurement so a late callback from
    /// the outgoing view can never resize the newly-switched window.
    var onContentHeightChange: (_ pageMode: Bool, _ height: CGFloat) -> Void
    /// Measured height of everything above the result list (toolbar, input,
    /// language bar, divider). Reported so the window fits exactly instead of
    /// relying on a fixed estimate that leaves a gap when the input is short.
    var onChromeHeightChange: (CGFloat) -> Void
    /// Page mode toggled. Driven from the same SwiftUI update that swaps the
    /// result content, so the window width and the content can never disagree
    /// (which happened when width was a separate Combine observation).
    var onModeChange: (Bool) -> Void
    var onClose: () -> Void

    var body: some View {
        mainColumn
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Drop the content min-height while recognizing so the panel can fit tight
        // to the chrome (no reserved result area) instead of padding out a gap.
        .frame(minWidth: 304, minHeight: viewModel.ocrRecognizing ? 0 : 220)
        // Float the LLM metrics card next to whichever header gauge is active.
        // An in-window overlay (not a `.popover`) so opening/closing it never
        // spins up a separate window that would race the page-mode resize.
        .overlayPreferenceValue(MetricsAnchorKey.self) { anchor in
            metricsOverlay(anchor)
        }
        .onChange(of: viewModel.pageMode) { _, isPage in onModeChange(isPage) }
        .background(AppleTranslationHostView())
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        // Notice floats as a toast so showing/hiding it never changes the
        // measured height (and thus never resizes the window).
        .overlay(alignment: .bottom) {
            if let notice = viewModel.notice {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(notice)
                        .lineLimit(2)
                    if let action = viewModel.noticeAction {
                        Button(action.title) { action.handler() }
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.15)))
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
    }

    /// Toolbar / input / language bar / results. The OCR image, when present,
    /// rides inside the input box as an attachment (see `InputSectionView`), so
    /// this stays the single-column layout for every flow.
    private var mainColumn: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                PanelToolbarView(
                    viewModel: viewModel,
                    hasResults: !run.runs.isEmpty,
                    onClose: onClose
                )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    // The toolbar strip is the panel's only drag region (window-
                    // background dragging is off so scrollbars scroll instead of
                    // moving the window). The handle sits behind the buttons, so
                    // empty toolbar space drags and the buttons still click.
                    .background(WindowDragHandle())

                InputSectionView(viewModel: viewModel, run: run)
                    .padding(.horizontal, 12)
                    // While recognizing the input box is the last element (language
                    // bar / results hidden), so give it a bottom margin matching
                    // its side insets instead of sitting flush against the edge.
                    .padding(.bottom, viewModel.ocrRecognizing ? 12 : 0)

                // While recognizing there's no text yet, so there's nothing to
                // detect a language from (showing a stale source→target pair is
                // misleading) and nothing to translate. Hide the language bar and
                // the separator above the empty result area until recognition
                // finishes — the recognizing panel is just the image + "识别中…".
                if !viewModel.ocrRecognizing {
                    LanguageBarView(viewModel: viewModel)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                    Divider()
                }
            }
            // Pin to intrinsic height: when `refit` momentarily makes the window
            // shorter than the content, SwiftUI would otherwise compress this
            // chrome, and that compressed height fed back into the next resize —
            // an oscillation that left a variable gap under the language bar.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                onChromeHeightChange($0)
            }

            if viewModel.pageMode {
                PageModeView(
                    viewModel: viewModel,
                    run: run,
                    onResultsHeightChange: { onContentHeightChange(true, $0) }
                )
                .id(viewModel.pageModePresentationID)
            } else {
                ResultListView(
                    viewModel: viewModel,
                    run: run,
                    onResultsHeightChange: { onContentHeightChange(false, $0) }
                )
            }

            // Absorbs any window height beyond the content so the result area
            // keeps its intrinsic size (reliable measurement) and extra space
            // sits at the bottom, never as a gap above the toolbar.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The floating metrics card, positioned just below the active gauge and
    /// clamped within the panel, over a transparent tap-catcher that dismisses.
    @ViewBuilder
    private func metricsOverlay(_ anchor: Anchor<CGRect>?) -> some View {
        if let anchor,
           let runID = viewModel.metricsRunID,
           let engineRun = run.runs.first(where: { $0.id == runID }),
           let metrics = engineRun.metrics {
            GeometryReader { proxy in
                let gauge = proxy[anchor]
                let cardWidth: CGFloat = 240
                let x = min(max(8, gauge.minX), max(8, proxy.size.width - cardWidth - 8))
                ZStack(alignment: .topLeading) {
                    // Tap anywhere off the card to dismiss.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.metricsRunID = nil }
                    MetricsPopover(
                        metrics: metrics,
                        engineName: engineRun.name,
                        kind: engineRun.kind,
                        requestedModel: engineRun.requestedModel
                    )
                        .offset(x: x, y: gauge.maxY + 6)
                }
            }
        }
    }
}
