import AppKit

/// A borderless "lightbox" that shows the OCR capture full-size over a full-screen
/// dimming scrim. No titlebar / traffic lights to cover the image — click the
/// image, click the scrim, or press Esc to dismiss. `onClose` fires whenever it
/// goes away, so the caller can drop the panel's outside-click suppression.
@MainActor
final class ImagePreviewController: NSObject {
    /// Called when the viewer closes (image click, scrim click, Esc, or `close()`).
    var onClose: (() -> Void)?

    private var window: LightboxWindow?
    private var scrim: NSWindow?
    /// Guards `onClose` against firing twice (e.g. scrim click races the window).
    private var isDismissing = false

    func show(_ image: NSImage) {
        if window == nil { build() }
        guard let window, let imageView = window.contentView as? NSImageView else { return }
        isDismissing = false
        imageView.image = image

        // Fit within 85% of the visible screen; don't upscale past the image's own
        // pixels (keeps text crisp). Floor to a usable minimum.
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = visible.width * 0.85, maxH = visible.height * 0.85
        var size = image.size
        let scale = min(maxW / size.width, maxH / size.height, 1)
        size = NSSize(width: max(size.width * scale, 240), height: max(size.height * scale, 160))

        showScrim()
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        dismiss()
    }

    /// Tear down the lightbox + scrim and notify once.
    private func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        window?.orderOut(nil)
        scrim?.orderOut(nil)
        scrim = nil
        onClose?()
    }

    private func showScrim() {
        // One borderless window spanning every screen, so background windows on
        // any display can't be clicked while viewing.
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let frame = union.isEmpty ? (NSScreen.main?.frame ?? .zero) : union

        let scrim = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        scrim.isOpaque = false
        scrim.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        scrim.level = .floating
        scrim.ignoresMouseEvents = false
        scrim.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        scrim.hasShadow = false
        let catcher = ClickView()
        catcher.onClick = { [weak self] in self?.dismiss() }
        scrim.contentView = catcher
        scrim.setFrame(frame, display: false)
        scrim.orderFront(nil)
        self.scrim = scrim
    }

    private func build() {
        let win = LightboxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        // Above the scrim (which is `.floating`) so the image stays on top.
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        win.onDismiss = { [weak self] in self?.dismiss() }

        let imageView = ClickImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        imageView.onClick = { [weak self] in self?.dismiss() }
        win.contentView = imageView

        window = win
    }
}

/// Borderless lightbox window that can still become key (for Esc) and closes on
/// Esc via the standard `cancelOperation` responder hook.
final class LightboxWindow: NSWindow {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

/// Image view that dismisses on click (so clicking the lightbox closes it).
private final class ClickImageView: NSImageView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Full-screen scrim content: swallows clicks (so background windows aren't
/// reachable) and dismisses the viewer on any click.
private final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
