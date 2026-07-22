import SwiftUI

/// Vertically stacked result cards, one per enabled engine. Each card body
/// scrolls independently; the whole list also becomes scrollable when the cards'
/// headers, footers and minimum body viewports cannot fit in the remaining panel
/// height. Without that second layer the last provider was clipped below the
/// window and could never be reached.
struct ResultListView: View {
    @ObservedObject var viewModel: PanelViewModel
    @ObservedObject var run: TranslationRunController
    var onResultsHeightChange: (CGFloat) -> Void
    @State private var measuredCardStackHeight: CGFloat = 0
    /// Each card's reported natural body height (see
    /// `ResultCardView.naturalBodyNeed`), keyed by engine id. Feeds the
    /// water-filling budget split; missing/nil entries claim an even share.
    @State private var bodyNeeds: [String: CGFloat?] = [:]

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                onResultsHeightChange($0)
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.ocrRecognizing {
            // Recognizing: nothing to translate yet. Render nothing so the result
            // area collapses (no reserved hint height under the input).
            Color.clear.frame(height: 0)
        } else if run.runs.isEmpty {
            // Keep the placeholder's footprint stable, but hide its text while a
            // notice toast floats over this same spot (they'd overlap).
            Text("回车翻译，Shift+回车换行")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .opacity(viewModel.notice == nil ? 1 : 0)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
        } else {
            ScrollView(.vertical) {
                VStack(spacing: Self.cardSpacing) {
                    let caps = perCardCaps
                    ForEach(Array(run.runs.enumerated()), id: \.element.id) { index, engineRun in
                        ResultCardView(
                            engineRun: engineRun,
                            isCollapsed: viewModel.collapsedBinding(for: engineRun.id),
                            metricsPresented: viewModel.metricsPopoverBinding(for: engineRun.id),
                            targetLanguage: run.targetLanguage,
                            maxBodyHeight: caps.indices.contains(index) ? caps[index] : 96,
                            layoutFrozen: viewModel.windowDragActive,
                            onRetry: { run.retry(runID: engineRun.id) },
                            onDownloadApple: { source, target in
                                run.downloadAppleLanguagePack(
                                    runID: engineRun.id, source: source, target: target
                                )
                            },
                            onBodyNeedChange: { bodyNeeds.updateValue($0, forKey: engineRun.id) }
                        )
                    }
                }
                .padding(.horizontal, Self.listHorizontalPadding)
                .padding(.vertical, Self.listVerticalPadding)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    measuredCardStackHeight = $0
                }
            }
            .frame(height: listViewportHeight)
            .scrollIndicators(.automatic)
            .accessibilityIdentifier("results.listScroll")
            .onChange(of: run.runGeneration) { _, _ in bodyNeeds = [:] }
        }
    }

    /// Natural height until the stack reaches the panel's live result budget;
    /// after that this is a fixed outer viewport and the provider list scrolls.
    private var listViewportHeight: CGFloat {
        let estimated = Self.minimumEstimatedStackHeight(cardCount: run.runs.count)
        return PanelLayout.scrollViewportHeight(
            content: measuredCardStackHeight > 1 ? measuredCardStackHeight : estimated,
            budget: viewModel.resultAreaBudget
        )
    }

    /// Per-card body ceilings (in `run.runs` order), shrinking as more
    /// providers share the window so every header/footer stays visible.
    /// Water-filling instead of an even split: a settled short or collapsed
    /// card releases its unused share to the clipped card next to it, so the
    /// stack can actually reach the budget (an even split left the tall card
    /// clipped at half the window while the short card's share sat empty).
    private var perCardCaps: [CGFloat] {
        // Budget is the live result-area height (window ceiling − chrome),
        // published by the panel, minus this view's own vertical padding (10+10).
        // So the cards shrink when the input/chrome is tall and the total always
        // fits — never pushing the bottom card off-screen with no scrollbar.
        PanelLayout.cardBodyCaps(
            needs: run.runs.map { engineRun -> CGFloat? in
                if viewModel.collapsedEngineIDs.contains(engineRun.id) { return 0 }
                return bodyNeeds[engineRun.id] ?? nil
            },
            budget: viewModel.resultAreaBudget
                - Self.listVerticalPadding * 2
                - Self.cardSpacing * CGFloat(max(0, run.runs.count - 1)),
            cardChrome: Self.cardChrome,
            floor: 96,
            capLimit: PanelLayout.maxAutoBodyHeight
        )
    }

    /// Header + divider/grab band + footer around each card's body.
    private static let cardChrome: CGFloat = 90
    private static let cardSpacing: CGFloat = 8
    private static let listHorizontalPadding: CGFloat = 12
    private static let listVerticalPadding: CGFloat = 10
    private static let minimumBodyEstimate: CGFloat = 40

    private static func minimumEstimatedStackHeight(cardCount: Int) -> CGFloat {
        let count = max(0, cardCount)
        return listVerticalPadding * 2
            + CGFloat(count) * (cardChrome + minimumBodyEstimate)
            + CGFloat(max(0, count - 1)) * cardSpacing
    }
}
