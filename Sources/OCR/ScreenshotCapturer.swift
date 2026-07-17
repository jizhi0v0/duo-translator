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
    static func captureRegion() async throws -> CaptureResult {
        guard PermissionCenter.hasScreenCapture else {
            PermissionCenter.requestScreenCapture()
            throw ScreenshotError.permissionNeeded
        }

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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenshotError.captureFailed
        }
        return .image(image)
    }
}
