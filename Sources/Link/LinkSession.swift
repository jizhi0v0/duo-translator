import AppKit
import Combine

/// One link-translation interaction: the source URL plus the live fetch state.
/// Mirrors `OCRSession` — an async source that produces text which then flows
/// into the panel's input box and hands off to the normal translate flow. The
/// fetched article body lands in `PanelViewModel.inputText`; page mode renders
/// it as a bilingual reader. Kept alive after hand-off so the link chip can
/// re-fetch.
@MainActor
final class LinkSession: ObservableObject {
    let url: URL

    enum Phase: Equatable {
        case fetching
        case done
        case empty
        case failed(String)
    }

    @Published var phase: Phase = .fetching
    /// Article title from Readability, shown in the link chip. Nil until fetched.
    @Published var title: String?
    /// Extracted article body, mirrored into `PanelViewModel.inputText` on
    /// success and kept here so a re-fetch can repopulate without losing it.
    @Published var text: String = ""
    /// Optional remediation button for the failed state (e.g. 打开设置 to pick a
    /// browser when none is available). Self-contained on the session so link
    /// errors never route through `showNotice`.
    @Published var action: PanelNoticeAction?

    /// Re-run the fetch on the same URL, injected by `AppCoordinator` (which owns
    /// the fetcher). Invoked by the chip's 重新抓取 button.
    var reFetch: (@MainActor () -> Void)?

    init(url: URL) {
        self.url = url
    }

    /// Host shown in the chip subtitle (e.g. "en.wikipedia.org").
    var host: String { url.host ?? url.absoluteString }
}
