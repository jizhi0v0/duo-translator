import SwiftUI

/// Page mode: replaces the stacked cards with a single provider's output shown
/// large. A provider selector sits on top; below is that provider's translation,
/// optionally side-by-side with the original (双语对照). The panel widens in this
/// mode (handled by `PanelController`) so two columns have room.
struct PageModeView: View {
    @ObservedObject var viewModel: PanelViewModel
    @ObservedObject var run: TranslationRunController
    /// Reports the page height (selector + fitted output) so the panel fits the
    /// content instead of always filling the budget.
    var onResultsHeightChange: (CGFloat) -> Void

    /// Live-measured heights: the selector bar (+divider) and the output's
    /// natural content height. The output area then fits its content up to the
    /// remaining budget, scrolling past that — same "grow then scroll" rule as
    /// the compact cards, so short content doesn't leave a tall empty page.
    @State private var selectorHeight: CGFloat = 44
    @State private var contentHeight: CGFloat = Self.outputFloor

    private static let outputFloor: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                selectorBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { selectorHeight = $0 }

            ScrollView {
                outputBody
                    .padding(16)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .frame(height: outputDisplayed)
        }
        .onAppear { onResultsHeightChange(reportedHeight) }
        .onChange(of: reportedHeight) { _, h in onResultsHeightChange(h) }
    }

    @ViewBuilder
    private var outputBody: some View {
        if let selected = selectedRun {
            PageModeContent(
                engineRun: selected,
                original: run.lastSourceText ?? viewModel.inputText,
                targetLanguage: run.targetLanguage,
                bilingual: viewModel.pageBilingual
            )
        } else {
            Text("暂无结果")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }

    /// Ceiling for the output area: the result-area budget minus the selector
    /// bar. Past it the output scrolls instead of the window growing.
    private var outputCap: CGFloat {
        max(Self.outputFloor, viewModel.resultAreaBudget - selectorHeight)
    }
    private var outputDisplayed: CGFloat {
        min(max(contentHeight, Self.outputFloor), outputCap)
    }
    private var reportedHeight: CGFloat { selectorHeight + outputDisplayed }

    private var selectedRun: EngineRunModel? {
        let id = PageModeLayout.resolvedProvider(
            ids: run.runs.map(\.id), selected: viewModel.pageProviderID
        )
        return run.runs.first { $0.id == id }
    }

    private var selectorBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: providerBinding) {
                ForEach(run.runs) { r in
                    Text(r.name).tag(r.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Spacer(minLength: 8)

            Picker("", selection: $viewModel.pageBilingual) {
                Text("对照").tag(true)
                Text("仅译文").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    /// Binds the segmented selection to `pageProviderID`, defaulting to the first
    /// run's id so the control always shows a valid selection.
    private var providerBinding: Binding<String> {
        Binding(
            get: { selectedRun?.id ?? "" },
            set: { viewModel.pageProviderID = $0 }
        )
    }
}

/// The selected provider's output. Observes the run model so it refreshes when
/// the translation finishes (the streaming buffer itself isn't observable, but
/// the run's `state`/`hasContent` are, and re-render re-reads `fullText`).
private struct PageModeContent: View {
    @ObservedObject var engineRun: EngineRunModel
    let original: String
    let targetLanguage: String?
    let bilingual: Bool

    var body: some View {
        let translation = engineRun.stream.fullText
        if bilingual {
            // Two whole-text columns, each rendered verbatim so every line break
            // and blank line (i.e. the paragraph structure) is preserved. Both
            // are top-aligned; the taller column sets the row height and the
            // whole area scrolls.
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    header("原文")
                    paragraph(original)
                }
                VStack(alignment: .leading, spacing: 8) {
                    header(targetName)
                    paragraph(translation.isEmpty ? "（暂无译文）" : translation)
                }
            }
        } else {
            paragraph(translation.isEmpty ? "（暂无译文）" : translation)
        }
    }

    private func paragraph(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 14))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ s: String) -> some View {
        Text(s)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var targetName: String {
        targetLanguage.map { LanguagePolicy.localizedName(for: $0) } ?? "译文"
    }
}

/// Pure page-mode helpers, factored out of the views so the provider-selection
/// rule can be unit-tested without a running UI.
enum PageModeLayout {
    /// The provider to show: the current selection if still present, else the
    /// first available, else nil (no runs).
    static func resolvedProvider(ids: [String], selected: String?) -> String? {
        if let selected, ids.contains(selected) { return selected }
        return ids.first
    }
}
