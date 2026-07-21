import AppKit
import Combine
import CoreGraphics

/// One screenshot-OCR interaction: the captured image plus the live recognition
/// state. Drives the dedicated OCR view (image on the left, recognition on the
/// right); the recognized text flows into the panel's input box, so pressing 回车
/// hands straight off to the normal translate flow. Kept alive after that hand-off
/// too, so the toolbar thumbnail can re-open this view to re-inspect / re-OCR.
@MainActor
final class OCRSession: ObservableObject {
    /// Retained for re-OCR (recognition consumes a `CGImage`, not the NSImage).
    let cgImage: CGImage
    let image: NSImage

    enum Phase: Equatable {
        case recognizing
        case done
        case empty
        case failed(String)
    }

    @Published var phase: Phase = .recognizing
    /// Recognized text, mirrored into `PanelViewModel.inputText` on success. Kept
    /// here too so a re-OCR can repopulate the input without losing the source.
    @Published var text: String = ""
    /// Optional action button for the failed / empty state (e.g. 打开系统设置 for a
    /// missing Screen Recording grant). Self-contained on the session so OCR
    /// errors never route through `showNotice`.
    @Published var action: PanelNoticeAction?

    /// Re-run recognition on the same image, injected by `AppCoordinator` (which
    /// owns the OCR provider). Invoked by the 重新识别 button.
    var reRecognize: (@MainActor () -> Void)?
    /// Open the full-size image viewer, injected by `AppCoordinator` (which owns
    /// the preview window). Invoked by tapping the attachment thumbnail.
    var onView: (@MainActor () -> Void)?

    init(cgImage: CGImage) {
        self.cgImage = cgImage
        self.image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
