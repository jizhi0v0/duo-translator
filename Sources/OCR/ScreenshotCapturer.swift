import AppKit
import ImageIO

@MainActor
enum ScreenshotCapturer {
    enum ScreenshotError: LocalizedError {
        case permissionNeeded
        case captureFailed

        var errorDescription: String? {
            switch self {
            case .permissionNeeded:
                return "需要屏幕录制权限。授权后请重启 DuoTranslator 再试。"
            case .captureFailed:
                return "截图失败。"
            }
        }
    }

    enum CaptureResult {
        case image(CGImage)
        case cancelled
    }

    /// Interactive region capture via the system `screencapture` tool — free
    /// crosshair UI, ESC cancels (no file is written), TCC attributes the
    /// permission to this app.
    ///
    /// We deliberately do NOT gate on `CGPreflightScreenCaptureAccess()`:
    /// interactive capture is user-initiated and works even when the preflight
    /// reads false, which it routinely does right after a grant (before an app
    /// restart) or after the app bundle is replaced. Blocking on it stranded the
    /// user on "需要屏幕录制权限" even after they granted it. The caller instead
    /// surfaces the permission hint from the *recognized* result — a blank
    /// screenshot yields no text, and only then do we point at System Settings.
    static func captureRegion() async throws -> CaptureResult {
        Log.capture.debug("OCR: 截图开始 hasScreenCapture=\(PermissionCenter.hasScreenCapture)")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("duo-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path] // -x: no shutter sound
        do {
            try process.run()
        } catch {
            throw ScreenshotError.captureFailed
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? Int ?? 0) > 0 else {
            return .cancelled // ESC pressed
        }
        // Force a full, immediate decode. The `defer` above deletes this temp
        // file the moment we return, and the `CGImageSource` goes out of scope
        // too — so a lazily-decoded CGImage would read blank when Vision finally
        // touches it (on a later detached task), silently yielding zero text.
        // `kCGImageSourceShouldCacheImmediately` materializes the pixels now,
        // while the file still exists.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else {
            throw ScreenshotError.captureFailed
        }
        Log.capture.debug("OCR: 截图完成 \(image.width)x\(image.height)")
        return .image(image)
    }
}
