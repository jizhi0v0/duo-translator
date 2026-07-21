import AppKit
import KeyboardShortcuts

/// A minimal keyboard-shortcut recorder.
///
/// The library's built-in `KeyboardShortcuts.Recorder` is an `NSSearchField`,
/// and on macOS 26 a mouse click on it drops into the window's field editor
/// (plain text-edit mode) instead of shortcut-record mode — so keystrokes get
/// typed as text and the ✕ clear button misbehaves. Rather than keep patching
/// that, this control captures the keystroke itself with a local event monitor
/// and uses `KeyboardShortcuts` only for storage + hotkey registration (which
/// work fine). No field editor, so recording and clearing are both reliable.
final class ShortcutRecorderView: NSView {
    /// The recorder currently listening, so starting one stops the others.
    private static weak var recording: ShortcutRecorderView?

    private let name: KeyboardShortcuts.Name
    /// The other shortcuts we manage, to warn on duplicates.
    private let siblings: [(name: KeyboardShortcuts.Name, title: String)]
    private let recordButton = NSButton()
    private let clearButton = NSButton()
    private var monitor: Any?
    private var isRecording = false { didSet { refresh() } }

    init(name: KeyboardShortcuts.Name, siblings: [(name: KeyboardShortcuts.Name, title: String)]) {
        self.name = name
        self.siblings = siblings
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        recordButton.bezelStyle = .rounded
        recordButton.setButtonType(.momentaryPushIn)
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.translatesAutoresizingMaskIntoConstraints = false

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "清除")
        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(recordButton)
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            recordButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            recordButton.topAnchor.constraint(equalTo: topAnchor),
            recordButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            recordButton.widthAnchor.constraint(equalToConstant: 170),
            clearButton.leadingAnchor.constraint(equalTo: recordButton.trailingAnchor, constant: 6),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { stopRecording() }

    // MARK: - Recording

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        Self.recording?.stopRecording()
        Self.recording = self
        setEditMonitorPaused(true)
        // Suspend the app's live global hotkeys while capturing: otherwise
        // pressing a combo that is already an assigned shortcut fires that
        // shortcut's action (e.g. triggers 划词翻译) instead of being recorded.
        KeyboardShortcuts.isEnabled = false
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }

            if event.type == .leftMouseDown {
                // A click anywhere but this control cancels recording (the click
                // itself proceeds normally).
                let p = self.recordButton.convert(event.locationInWindow, from: nil)
                if !self.recordButton.bounds.contains(p) { self.stopRecording() }
                return event
            }

            switch event.keyCode {
            case 53: // Escape — cancel
                self.stopRecording()
                return nil
            case 51, 117: // Delete / Forward-delete — clear
                KeyboardShortcuts.setShortcut(nil, for: self.name)
                self.stopRecording()
                return nil
            default:
                // Require at least one of Command/Control/Option (Shift alone
                // doesn't make a usable global shortcut).
                let mods = event.modifierFlags.intersection([.command, .control, .option])
                guard !mods.isEmpty, let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
                    NSSound.beep()
                    return nil
                }
                self.stopRecording()
                self.commit(shortcut)
                return nil
            }
        }
        refresh()
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if Self.recording === self { Self.recording = nil }
        if isRecording {
            isRecording = false
            setEditMonitorPaused(false)
            KeyboardShortcuts.isEnabled = true
        }
    }

    /// Validate a captured shortcut and store it, warning on conflicts. Runs
    /// after recording has stopped, so the modal alerts don't re-enter the
    /// event monitor.
    private func commit(_ shortcut: KeyboardShortcuts.Shortcut) {
        if let clash = siblings.first(where: { KeyboardShortcuts.getShortcut(for: $0.name) == shortcut }) {
            NSSound.beep()
            alert(title: "快捷键冲突",
                  message: "「\(shortcut)」已被「\(clash.title)」使用，请换一个组合。")
            refresh()
            return
        }
        if shortcut.isTakenBySystem {
            let useAnyway = alert(
                title: "快捷键被系统占用",
                message: "「\(shortcut)」是系统快捷键，设为本 App 的快捷键可能不会触发。仍要使用吗？",
                buttons: ["仍要使用", "取消"]
            ) == .alertFirstButtonReturn
            guard useAnyway else { refresh(); return }
        }
        KeyboardShortcuts.setShortcut(shortcut, for: name)
        refresh()
    }

    @objc private func clearShortcut() {
        KeyboardShortcuts.setShortcut(nil, for: name)
        refresh()
    }

    // MARK: - Helpers

    /// Reuse the notification the AppDelegate's edit-key monitor already gates
    /// on, so it stands down while we're capturing (otherwise it eats ⌘C/⌘V/…).
    private func setEditMonitorPaused(_ paused: Bool) {
        NotificationCenter.default.post(
            name: Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange"),
            object: nil, userInfo: ["isActive": paused]
        )
    }

    @discardableResult
    private func alert(title: String, message: String, buttons: [String] = ["好"]) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        for b in buttons { a.addButton(withTitle: b) }
        return a.runModal()
    }

    private func refresh() {
        let current = KeyboardShortcuts.getShortcut(for: name)
        recordButton.title = isRecording ? "按下快捷键…" : (current.map { "\($0)" } ?? "点按录制")
        clearButton.isHidden = isRecording || current == nil
    }
}
