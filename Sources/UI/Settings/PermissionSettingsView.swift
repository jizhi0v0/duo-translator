import SwiftUI

/// New-user reliability: Accessibility (划词翻译) and Screen Recording (OCR) are
/// granted outside the app, in System Settings, and both features fail silently
/// without them. This pane makes that state visible and grantable in one place,
/// instead of only surfacing a system prompt the first time a hotkey is pressed.
///
/// Grants happen in another process, so we poll while the pane is on screen
/// rather than trust a one-shot read — the checkmark flips over to reflect a
/// grant the user just made in System Settings without reopening the window.
struct PermissionSettingsView: View {
    @State private var accessibilityTrusted = false
    @State private var screenCaptureGranted = false

    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("辅助功能（划词翻译）") {
                PermissionRow(
                    granted: accessibilityTrusted,
                    grantedText: "已授权，⌥D 划词翻译可用。",
                    deniedText: "未授权。划词翻译需要读取其他 app 中选中的文本。",
                    request: { PermissionCenter.requestAccessibility() },
                    openSettings: { PermissionCenter.openAccessibilitySettings() }
                )
            }

            Section("屏幕录制（截图 OCR）") {
                PermissionRow(
                    granted: screenCaptureGranted,
                    grantedText: "已授权，⌥S / ⌥⇧S 截图翻译可用。",
                    deniedText: "未授权。截图 OCR 需要录制屏幕来框选取图。",
                    request: { PermissionCenter.requestScreenCapture() },
                    openSettings: { PermissionCenter.openScreenCaptureSettings() }
                )
                if !screenCaptureGranted {
                    Text("授权后需重启 App 才会生效（macOS 系统行为）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
    }

    private func reload() {
        accessibilityTrusted = PermissionCenter.isAccessibilityTrusted
        screenCaptureGranted = PermissionCenter.hasScreenCapture
    }
}

private struct PermissionRow: View {
    let granted: Bool
    let grantedText: String
    let deniedText: String
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Text(granted ? grantedText : deniedText)
                    .foregroundStyle(granted ? .primary : .secondary)
            }
            if !granted {
                HStack(spacing: 8) {
                    Button("请求授权", action: request)
                    Button("打开系统设置", action: openSettings)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
