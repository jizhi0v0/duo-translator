import SwiftUI

/// The input editor with a footer row (speak / copy of the source text) styled
/// to match the result cards — a divider above a leading row of actions.
struct InputSectionView: View {
    @ObservedObject var viewModel: PanelViewModel
    @ObservedObject var run: TranslationRunController
    @ObservedObject private var speech = SpeechService.shared

    @FocusState private var inputFocused: Bool
    /// Live content height of the editor, measured from a hidden text mirror so
    /// the box grows with what's typed instead of sitting at a fixed size.
    @State private var contentHeight: CGFloat = minEditorHeight

    /// Auto-growing input: starts at ~one line and grows with content up to a
    /// ceiling, past which the text scrolls inside the box. The panel's chrome
    /// measurement follows this, so the window grows/shrinks to match.
    private static let minEditorHeight: CGFloat = 60
    /// Shared with the result cards' auto ceiling (`PanelLayout.maxAutoBodyHeight`
    /// is derived from it), so the input and a result top out together.
    private static let maxEditorHeight: CGFloat = PanelLayout.maxInputHeight
    /// Horizontal inset for the measuring mirror: our `.padding(6)` plus the
    /// NSTextView text-container inset (~5), so the mirror wraps at the same
    /// width the editor does. Kept slightly generous so it over- rather than
    /// under-estimates — a hair of extra height beats clipping the last line.
    private static let editorInset: CGFloat = 11
    /// Vertical chrome added on top of the measured text height: the editor's
    /// own `.padding(6)` top+bottom plus the text-container's vertical inset.
    private static let editorVChrome: CGFloat = 22
    private static let font = Font.system(size: 13)
    /// Line spacing, shared by the editor and its measuring mirror so the
    /// growth height stays exact. A touch airier than the default so pasted
    /// multi-line source doesn't read cramped.
    private static let lineSpacing: CGFloat = 5

    /// Long text certainly overflows `maxEditorHeight`, so its exact height is
    /// irrelevant — the editor caps and scrolls internally either way. Skip the
    /// hidden full-text mirror in that case: laying out a few-thousand-char
    /// SwiftUI `Text` with `.fixedSize` is O(n) and unvirtualized, and was the
    /// bulk of the first-layout stall when a big selection is prefilled.
    private var skipsMirror: Bool { viewModel.inputText.count > 1000 }

    /// The editor is empty & disabled while an async source (OCR recognition or
    /// link fetch) is in flight — only a "…中" placeholder shows.
    private var inputBusy: Bool { viewModel.ocrRecognizing || viewModel.linkFetching }

    private var editorHeight: CGFloat {
        // While busy the editor is empty & disabled (just the placeholder). Pin
        // it compact so a stale `contentHeight` left over from a prior translation
        // doesn't keep the box tall (and the window oversized, leaving a gap)
        // until the async mirror re-measures.
        if inputBusy { return Self.minEditorHeight }
        if skipsMirror { return Self.maxEditorHeight }
        return PanelLayout.editorHeight(content: contentHeight, min: Self.minEditorHeight, max: Self.maxEditorHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            // OCR: the captured image rides at the top of the input box like a
            // chat composer's attachment, with recognition status. Everything
            // below (editor, language bar, results) is the normal panel.
            if let ocr = viewModel.ocr {
                OCRAttachmentBar(session: ocr, onRemove: { viewModel.ocr = nil })
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }

            // 链接翻译: the source-link chip rides at the top of the input box, the
            // same slot as the OCR attachment, with its fetch status.
            if let link = viewModel.link {
                LinkAttachmentBar(session: link, onRemove: { viewModel.link = nil })
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }

            TextEditor(text: $viewModel.inputText)
                .font(Self.font)
                .lineSpacing(Self.lineSpacing)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: editorHeight)
                .background(alignment: .topLeading) {
                    if !skipsMirror { heightMirror }
                }
                // "识别中…" placeholder while recognition is in flight (the editor
                // is empty then). Observes the session so it clears the moment the
                // text lands.
                .overlay(alignment: .topLeading) {
                    if let ocr = viewModel.ocr {
                        OCRRecognizingLabel(session: ocr)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    } else if viewModel.linkFetching {
                        BusyPlaceholder(text: "抓取正文中…")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                // While an async source is in flight there is nothing to edit yet:
                // disable the editor so it shows no cursor, takes no typing, and
                // swallows no Enter. It re-enables the moment the text lands.
                .disabled(inputBusy)
                .focused($inputFocused)
                .onKeyPress { press in
                    guard press.key == .return, !press.modifiers.contains(.shift) else {
                        return .ignored
                    }
                    viewModel.translateDebounced()
                    return .handled
                }
                .onChange(of: viewModel.focusToken) {
                    // Don't grab focus mid-fetch: the disabled editor would still
                    // blink a stray caret. Completion clears the flag and bumps
                    // `focusToken` again to focus it then.
                    if !inputBusy { inputFocused = true }
                }
                .onChange(of: inputBusy) { _, busy in
                    // Entering a busy state: drop focus so no caret shows over the
                    // placeholder.
                    if busy { inputFocused = false }
                }
                .onAppear {
                    if !inputBusy { inputFocused = true }
                }

            Divider().padding(.horizontal, 10)
            footer
        }
        // Sit the input on the same `.thinMaterial` surface the result cards use,
        // not a 50%-opacity dynamic fill: over the translucent glass panel (and a
        // bright wallpaper behind it) the thin fill washed out, leaving the source
        // text low-contrast. The material gives a solid, readable backing in both
        // light and dark, matching the cards below.
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
    }

    /// Invisible copy of the text laid out at the editor's text width; its
    /// measured height drives `editorHeight` so the box grows with content.
    private var heightMirror: some View {
        Text(viewModel.inputText.isEmpty ? " " : viewModel.inputText)
            .font(Self.font)
            .lineSpacing(Self.lineSpacing)
            .padding(.horizontal, Self.editorInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { textHeight in
                contentHeight = textHeight + Self.editorVChrome
            }
            .hidden()
            .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                speech.toggle(
                    id: "input",
                    text: viewModel.inputText,
                    languageCode: run.detectedLanguage
                )
            } label: {
                Image(systemName: speech.speakingID == "input" ? "stop.fill" : "speaker.wave.2")
                    .font(.caption)
                    .frame(width: FooterIcon.width, height: FooterIcon.height)
            }
            .buttonStyle(.borderless)
            .help(speech.speakingID == "input" ? "停止朗读" : "朗读原文")
            .disabled(viewModel.inputText.isEmpty)
            .accessibilityIdentifier("input.speak")

            CopyButton(text: viewModel.inputText, help: "复制原文", identifier: "input.copy")

            Spacer()

            Label("回车翻译", systemImage: "return")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("在输入框按回车即可翻译")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 7)
    }
}

/// A compact spinner + label overlaid on the empty input editor while an async
/// source (currently the link fetch) is in flight. Mirrors `OCRRecognizingLabel`
/// but takes its text directly since it has no session to observe.
struct BusyPlaceholder: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Fixed footprint for the footer action icons (speak / copy) in the input and
/// result cards, so swapping a glyph never resizes the row. `height` pins both:
/// `checkmark` is taller than `doc.on.doc`. `width` pins only the speak button,
/// whose `speaker.wave.2`↔`stop.fill` states differ in width (copy's do not, so
/// it stays natural-width to sit snug against the speak button).
enum FooterIcon {
    static let width: CGFloat = 18
    static let height: CGFloat = 14
}

/// Copies `text` to the pasteboard and confirms by briefly flipping its icon to
/// a green checkmark (and its tooltip to "已复制") before reverting. Disabled
/// when there's nothing to copy. Shared by the input footer and result cards so
/// the copy affordance behaves identically everywhere.
struct CopyButton: View {
    let text: String
    var help: String = "复制"
    /// Accessibility identifier for UI tests (e.g. "input.copy"). The button's
    /// accessibility value reports "copied"/"idle" so a test can assert the
    /// confirmation feedback appears and then reverts.
    var identifier: String? = nil

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                // Pin only the height: `checkmark` is taller than `doc.on.doc`
                // and would otherwise resize the row. Their widths match, so
                // leaving width natural keeps the icon snug to its neighbor
                // instead of floating in an over-wide box.
                .frame(height: FooterIcon.height)
        }
        .buttonStyle(.borderless)
        .help(copied ? "已复制" : help)
        .disabled(text.isEmpty)
        .accessibilityIdentifier(identifier ?? "")
        .accessibilityValue(copied ? "copied" : "idle")
    }

    private func copy() {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.15)) { copied = false }
        }
    }
}
