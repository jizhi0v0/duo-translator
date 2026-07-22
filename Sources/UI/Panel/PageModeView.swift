import AppKit
import SwiftUI

/// Page mode: replaces the stacked cards with a single provider's output shown
/// large. A provider selector sits on top; below is that provider's translation,
/// optionally preceded by the complete original (双语对照). The panel widens in
/// this mode (handled by `PanelController`) for a roomy reading layout.
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
    /// the output stays at its compact loading floor. Using the full budget here
    /// makes the selector's first geometry update report a ceiling-sized page
    /// when the user switches modes before the first translation chunk arrives.
    @State private var contentHeight: CGFloat?
    /// Jump-to-latest affordance state, mirroring the result cards.
    @State private var canJumpToBottom = false
    @State private var jumpToken = 0

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
                .overlay(alignment: .bottomTrailing) {
                    if canJumpToBottom, selectedIsStreaming {
                        FollowStreamButton(identifier: "page.followStream") {
                            jumpToken += 1
                        }
                    }
                }
        }
        // An empty streaming run has no TextKit measurement yet, so publish the
        // compact loading height immediately. For an existing translation, keep
        // the controller's old height until TextKit reports at the new page
        // width; publishing the floor there would cause a short→tall flash.
        .onAppear {
            if selectedTextIsEmpty {
                onResultsHeightChange(selectorHeight + Self.outputFloor)
            }
        }
        .onChange(of: contentHeight) { _, height in
            if height != nil { onResultsHeightChange(reportedHeight) }
        }
        .onChange(of: reportedHeight) { _, h in
            // While an existing body is still being measured, don't let a
            // selector/budget geometry change publish the temporary floor.
            if contentHeight != nil || selectedTextIsEmpty {
                onResultsHeightChange(h)
            }
        }
    }

    @ViewBuilder
    private var outputBody: some View {
        if let selected = selectedRun {
            PageModeContent(
                engineRun: selected,
                original: run.lastSourceText ?? viewModel.inputText,
                bilingual: viewModel.pageBilingual,
                heightCeiling: outputCap,
                suppressFollow: viewModel.windowDragActive,
                jumpToBottomToken: jumpToken,
                onHeight: { contentHeight = $0 },
                onScrollStateChange: { canJumpToBottom = $0 }
            )
        } else {
            Text("暂无结果")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var selectedIsStreaming: Bool {
        if case .streaming? = selectedRun?.state { return true }
        return false
    }

    /// Ceiling for the output area: the result-area budget minus the selector
    /// bar. Past it the output scrolls instead of the window growing.
    private var outputCap: CGFloat {
        max(Self.outputFloor, viewModel.resultAreaBudget - selectorHeight)
    }
    private var outputDisplayed: CGFloat {
        PageModeLayout.outputHeight(
            measured: contentHeight,
            floor: Self.outputFloor,
            cap: outputCap
        )
    }
    private var reportedHeight: CGFloat { selectorHeight + outputDisplayed }

    /// `fullText`, rather than `hasContent`, is authoritative here: the latter
    /// flips before the streaming buffer's first coalesced flush, while the page
    /// reader still contains only "翻译中…".
    private var selectedTextIsEmpty: Bool {
        selectedRun?.stream.fullText.isEmpty ?? true
    }

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

/// The selected provider's output. The AppKit reader binds directly to the
/// streaming model: chunks append to its text storage even though SwiftUI does
/// not re-render for every delta.
private struct PageModeContent: View {
    @ObservedObject var engineRun: EngineRunModel
    let original: String
    let bilingual: Bool
    let heightCeiling: CGFloat
    let suppressFollow: Bool
    let jumpToBottomToken: Int
    var onHeight: (CGFloat) -> Void
    var onScrollStateChange: (Bool) -> Void

    var body: some View {
        PageReaderView(
            model: engineRun.stream,
            original: original,
            bilingual: bilingual,
            placeholder: placeholder,
            streamSettled: streamSettled,
            resetKey: engineRun.id,
            heightCeiling: heightCeiling,
            suppressFollow: suppressFollow,
            jumpToBottomToken: jumpToBottomToken,
            onContentHeightChange: onHeight,
            onScrollStateChange: onScrollStateChange
        )
    }

    private var placeholder: String {
        if case .streaming = engineRun.state { return "翻译中…" }
        return "暂无译文"
    }

    /// The run stopped streaming (done / failed / needs-download) — 对照 may
    /// now append the original's unpaired remainder.
    private var streamSettled: Bool {
        if case .streaming = engineRun.state { return false }
        return true
    }
}

/// Pure page-mode helpers, factored out of the views so the provider-selection
/// rule can be unit-tested without a running UI.
enum PageModeLayout {
    struct TextBlock: Equatable {
        enum Role: Equatable { case source, translation, placeholder }
        let text: String
        let role: Role
    }

    /// Blocks rendered by the page reader. Before the first chunk only the
    /// compact placeholder is shown. Bilingual 对照 interleaves paragraph by
    /// paragraph (原[i], 译[i], 原[i+1], …), filling top-down as the translation
    /// streams — the projection only ever *extends* while text appends, so the
    /// reader can stay append-only. Nothing is truncated: translation
    /// paragraphs beyond the original's count always show, and once the run
    /// settles the original's unpaired remainder is appended too (an engine
    /// that merged paragraphs can't silently drop source text).
    static func textBlocks(
        original: String,
        translation: String,
        bilingual: Bool,
        placeholder: String,
        settled: Bool = true
    ) -> [TextBlock] {
        guard !translation.isEmpty else {
            return [TextBlock(text: placeholder, role: .placeholder)]
        }
        guard bilingual, !original.isEmpty else {
            return [TextBlock(text: translation, role: .translation)]
        }
        var o = paragraphUnits(original)
        var t = paragraphUnits(translation)
        // 划词 capture frequently loses newlines (AX text of many apps comes
        // back flat), which collapses the source to ONE paragraph unit and
        // degenerates 对照 into "whole source, then all translation". When the
        // source has no usable paragraph structure but does split into
        // sentences, pair sentence-by-sentence instead.
        if o.count <= 1 {
            let sourceSentences = sentenceUnits(original)
            if sourceSentences.count >= 2 {
                o = sourceSentences
                t = sentenceUnits(translation)
            }
        }
        let pairs = Swift.min(o.count, t.count)
        var blocks: [TextBlock] = []
        for i in 0..<pairs {
            blocks.append(TextBlock(text: o[i], role: .source))
            blocks.append(TextBlock(text: t[i], role: .translation))
        }
        for i in pairs..<t.count {
            blocks.append(TextBlock(text: t[i], role: .translation))
        }
        if settled {
            for i in pairs..<o.count {
                blocks.append(TextBlock(text: o[i], role: .source))
            }
        }
        return blocks
    }

    /// Non-empty, trimmed lines — the paragraph units 对照 pairs by index.
    /// Blank lines are dropped: they're only spacing, and some engines (e.g.
    /// Apple) separate paragraphs with an extra blank line while others don't;
    /// ignoring blanks keeps both sides in step.
    static func paragraphUnits(_ s: String) -> [String] {
        s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Sentence units for flat (newline-less) text. CJK terminators always end
    /// a sentence; Latin ones only when followed by whitespace/end, so
    /// decimals ("1.5s") and versions ("v3.2") don't split.
    static func sentenceUnits(_ s: String) -> [String] {
        let cjkTerminators: Set<Character> = ["。", "！", "？", "…", "；"]
        let latinTerminators: Set<Character> = [".", "!", "?", ";"]
        var units: [String] = []
        var current = ""
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            let isBoundary: Bool
            if cjkTerminators.contains(ch) {
                isBoundary = true
            } else if latinTerminators.contains(ch) {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                isBoundary = next == " " || next == "\n" || next == "\t"
            } else {
                isBoundary = false
            }
            if isBoundary {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { units.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { units.append(tail) }
        return units
    }

    /// Height used by page mode before/after TextKit's first measurement. An
    /// unmeasured loading reader must stay compact instead of borrowing the full
    /// result budget and accidentally stretching the panel to its ceiling.
    static func outputHeight(measured: CGFloat?, floor: CGFloat, cap: CGFloat) -> CGFloat {
        min(max(measured ?? floor, floor), cap)
    }

    /// The provider to show: the current selection if still present, else the
    /// first available, else nil (no runs).
    static func resolvedProvider(ids: [String], selected: String?) -> String? {
        if let selected, ids.contains(selected) { return selected }
        return ids.first
    }

}
