import AppKit
import ApplicationServices

@MainActor
enum PermissionCenter {
    // MARK: Accessibility (selection capture)

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt directing the user to System Settings.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Screen Recording (OCR capture)

    static var hasScreenCapture: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenCapture() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenCaptureSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
