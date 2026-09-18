import AppKit
import SwiftUI

/// 链接翻译 settings: pick which installed Chromium browser agent-browser drives
/// to fetch article bodies. agent-browser can't enumerate browsers, so we scan
/// the known Chromium apps ourselves (Chrome / Edge / Brave / Arc / …). "自动"
/// (empty path) uses the first detected browser.
struct LinkSettingsView: View {
    @ObservedObject var settings: SettingsStore

    /// Re-scanned on appear and after the user picks a custom app.
    @State private var browsers: [DetectedBrowser] = []

    private static let autoTag = ""

    var body: some View {
        Form {
            Section("抓取浏览器") {
                if browsers.isEmpty {
                    Label(
                        "未检测到 Chromium 内核浏览器。链接翻译需要 Chrome / Edge / Brave / Arc 等其中之一(Safari 不支持)。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    Picker("浏览器", selection: $settings.linkBrowserPath) {
                        Text("自动(第一个检测到的)").tag(Self.autoTag)
                        ForEach(browsers) { b in
                            Text(b.name).tag(b.path)
                        }
                    }
                    Text("链接翻译用它在后台无头抓取网页正文,再翻译。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("重新扫描") { rescan() }
                    Button("选择其他浏览器…") { chooseCustom() }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: rescan)
    }

    private func rescan() {
        browsers = BrowserScanner.detected()
        // Drop a stale saved path that no longer exists → fall back to 自动.
        if !settings.linkBrowserPath.isEmpty,
           !FileManager.default.isExecutableFile(atPath: settings.linkBrowserPath) {
            settings.linkBrowserPath = ""
        }
    }

    /// Let the user point at a browser .app we didn't enumerate; resolve it to the
    /// executable inside and remember it.
    private func chooseCustom() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        guard let exec = Self.executable(inAppBundle: appURL) else { return }
        // Surface it in the list and select it.
        let name = appURL.deletingPathExtension().lastPathComponent
        if !browsers.contains(where: { $0.path == exec }) {
            browsers.append(DetectedBrowser(name: name, path: exec))
        }
        settings.linkBrowserPath = exec
    }

    /// The main executable inside an .app bundle (`Contents/MacOS/<CFBundleExecutable>`).
    private static func executable(inAppBundle appURL: URL) -> String? {
        guard let bundle = Bundle(url: appURL),
              let exec = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: exec.path) else { return nil }
        return exec.path
    }
}
