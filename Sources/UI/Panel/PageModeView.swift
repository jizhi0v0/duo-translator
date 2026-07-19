import AppKit
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
    /// nil until the reader reports its first measured height. While unmeasured
    /// the output fills the budget (see `outputDisplayed`) so a long translation
    /// opens at full height instead of flashing from a tiny floor up to size.
    @State private var contentHeight: CGFloat?

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

            outputBody
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
                bilingual: viewModel.pageBilingual,
                onHeight: { contentHeight = $0 }
            )
        } else {
            Text("暂无结果")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Ceiling for the output area: the result-area budget minus the selector
    /// bar. Past it the output scrolls instead of the window growing.
    private var outputCap: CGFloat {
        max(Self.outputFloor, viewModel.resultAreaBudget - selectorHeight)
    }
    private var outputDisplayed: CGFloat {
        // Before the first measurement, fill the budget so long content opens at
        // full height; once measured, grow-then-cap like the compact cards.
        guard let h = contentHeight else { return outputCap }
        return min(max(h, Self.outputFloor), outputCap)
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
    let bilingual: Bool
    var onHeight: (CGFloat) -> Void

    var body: some View {
        PageReaderView(attributed: attributed, resetKey: engineRun.id, onContentHeightChange: onHeight)
    }

    /// 仅译文 = translation alone; 对照 interleaves each source paragraph (muted)
    /// with its translation (primary) by index, up to the number of paragraphs
    /// translated so far — so it fills in top-down as the text streams instead
    /// of flipping layout when the run completes.
    private var attributed: NSAttributedString {
        let translation = engineRun.stream.fullText
        guard !translation.isEmpty else {
            return Self.block(placeholder, color: .secondaryLabelColor, spacing: 10)
        }
        if !bilingual {
            return Self.block(translation, color: .labelColor, spacing: 10)
        }
        let o = PageModeLayout.paragraphUnits(original)
        let t = PageModeLayout.paragraphUnits(translation)
        let pairs = min(o.count, t.count)
        let out = NSMutableAttributedString()
        guard pairs > 0 else {
            // Nothing to pair yet (a side didn't split into paragraphs) — show
            // source then translation as blocks.
            out.append(Self.block(original, color: .secondaryLabelColor, spacing: 16))
            out.append(Self.block(translation, color: .labelColor, spacing: 0))
            return out
        }
        // Pair by index up to what's translated so far: interleaved from the
        // first chunk, filling in top-down as it streams — no flip at completion.
        for i in 0..<pairs {
            out.append(Self.block(o[i], color: .secondaryLabelColor, spacing: 3))
            out.append(Self.block(t[i], color: .labelColor, spacing: i < pairs - 1 ? 16 : 0))
        }
        return out
    }

    /// One paragraph run: `text` + trailing newline, colored, with `spacing`
    /// points of gap after it.
    private static func block(_ text: String, color: NSColor, spacing: CGFloat) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        para.paragraphSpacing = spacing
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: color,
            .paragraphStyle: para,
        ])
    }

    private var placeholder: String {
        if case .streaming = engineRun.state { return "翻译中…" }
        return "暂无译文"
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

    /// Non-empty, trimmed lines — the paragraph units the 对照 view pairs by
    /// index. Blank lines are dropped because they're only spacing (and some
    /// engines, e.g. Apple, separate paragraphs with an extra blank line while
    /// others don't; ignoring blanks keeps both sides in step).
    static func paragraphUnits(_ s: String) -> [String] {
        s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
