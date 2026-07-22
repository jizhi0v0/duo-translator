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

    /// Height of the toolbar/input/language-bar chrome above the results,
    /// measured alongside `onChromeHeightChange`. Fed to the metrics overlay so
    /// it can never place itself over the toolbar's buttons, even when flipped
    /// above a gauge near the top of a short panel.
    @State private var chromeHeight: CGFloat = 0

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
                chromeHeight = $0
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

    /// The floating metrics card. Its custom layout measures the real popover
    /// first, then places it below the gauge when possible, flips it above, or
    /// — on a panel too short for either — shrinks it to whatever room is left
    /// (see `MetricsOverlayPlacement.fit`); unlike a visual offset, placement
    /// participates in layout and hit testing.
    @ViewBuilder
    private func metricsOverlay(_ anchor: Anchor<CGRect>?) -> some View {
        if let anchor,
           let runID = viewModel.metricsRunID,
           let engineRun = run.runs.first(where: { $0.id == runID }),
           let metrics = engineRun.metrics {
            GeometryReader { proxy in
                let gauge = proxy[anchor]
                MetricsOverlayLayout(gauge: gauge, topInset: chromeHeight) {
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
                }
            }
        }
    }
}

/// Pure placement rule shared by the custom layout and unit tests.
enum MetricsOverlayPlacement {
    /// Where the card goes, and how tall it's allowed to render — capped to
    /// whatever room the chosen side actually has, so the card is never asked
    /// to overlap the trigger, the protected chrome, or the window edge. The
    /// card's own scroll view (see `MetricsPopover`) does the rest: content
    /// beyond `size.height` scrolls instead of spilling out.
    ///
    /// - Parameter topInset: height of the fixed chrome (toolbar / input /
    ///   language bar) above the results, out of bounds for the card even when
    ///   it flips above the gauge — that chrome holds the panel's own buttons
    ///   (pin, page mode, language pickers), which must stay clickable.
    static func fit(
        gauge: CGRect,
        naturalSize: CGSize,
        containerSize: CGSize,
        margin: CGFloat = 8,
        gap: CGFloat = 6,
        topInset: CGFloat = 0
    ) -> (origin: CGPoint, size: CGSize) {
        let maxX = max(margin, containerSize.width - margin - naturalSize.width)
        let x = min(max(gauge.minX, margin), maxX)

        let topBound = margin + topInset
        let bottomBound = containerSize.height - margin
        let roomBelow = bottomBound - (gauge.maxY + gap)
        let roomAbove = (gauge.minY - gap) - topBound

        // Prefer below when it holds the card at full height. Flip above only
        // if below can't but above can. If neither can, pick whichever side
        // has more room and let the card's own scroll view give up the rest —
        // it must shrink to fit there, not spill into the trigger row, the
        // chrome above, or past the window edge below.
        let useBelow: Bool
        if roomBelow >= naturalSize.height {
            useBelow = true
        } else if roomAbove >= naturalSize.height {
            useBelow = false
        } else {
            useBelow = roomBelow >= roomAbove
        }

        let room = useBelow ? roomBelow : roomAbove
        let height = min(naturalSize.height, max(1, room))
        let y = useBelow ? (gauge.maxY + gap) : (gauge.minY - gap - height)
        let clampedY = min(max(y, topBound), max(topBound, bottomBound - height))

        return (CGPoint(x: x, y: clampedY), CGSize(width: naturalSize.width, height: height))
    }
}

/// Measures the metrics card before positioning it, then proposes it whatever
/// height `fit` decided it gets. Child 0 is the full-panel dismiss catcher;
/// child 1 is the popover drawn above it.
private struct MetricsOverlayLayout: Layout {
    let gauge: CGRect
    let topInset: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count >= 2 else { return }
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )

        // Unconstrained height first, to learn how tall the card would like to
        // be; `fit` then caps that against the actual room and the card's own
        // scroll view (see `MetricsPopover`) absorbs the difference.
        let naturalSize = subviews[1].sizeThatFits(
            ProposedViewSize(width: 240, height: nil)
        )
        let placement = MetricsOverlayPlacement.fit(
            gauge: gauge,
            naturalSize: naturalSize,
            containerSize: bounds.size,
            topInset: topInset
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
            anchor: .topLeading,
            proposal: ProposedViewSize(placement.size)
        )
    }
}
