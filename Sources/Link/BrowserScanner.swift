import Foundation

/// A Chromium-based browser detected on disk, offered to the user for 链接翻译
/// (agent-browser drives it via `--executable-path`). agent-browser has no
/// "list browsers" command and only detects Chrome, so we enumerate the known
/// Chromium apps ourselves.
struct DetectedBrowser: Identifiable, Hashable {
    let name: String
    /// Full path to the browser's executable inside the .app bundle.
    let path: String
    var id: String { path }
}

enum BrowserScanner {
    /// Known Chromium browsers and their executable paths under /Applications.
    /// agent-browser only drives Chromium engines (no WebKit/Safari), so this
    /// list is Chromium-only.
    static let candidates: [(name: String, path: String)] = [
        ("Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        ("Microsoft Edge", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
        ("Brave Browser", "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"),
        ("Arc", "/Applications/Arc.app/Contents/MacOS/Arc"),
        ("Vivaldi", "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi"),
        ("Opera", "/Applications/Opera.app/Contents/MacOS/Opera"),
        ("Chromium", "/Applications/Chromium.app/Contents/MacOS/Chromium"),
        ("Google Chrome Canary", "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"),
    ]

    /// The installed subset of `candidates`. `fileExists` is injectable for tests.
    static func detected(
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [DetectedBrowser] {
        candidates
            .filter { fileExists($0.path) }
            .map { DetectedBrowser(name: $0.name, path: $0.path) }
    }

    /// The executable path to drive: the user's saved choice if it still exists,
    /// otherwise the first detected browser. Nil when none is available.
    static func resolve(
        preferred: String,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if !preferred.isEmpty, fileExists(preferred) { return preferred }
        return detected(fileExists: fileExists).first?.path
    }
}
