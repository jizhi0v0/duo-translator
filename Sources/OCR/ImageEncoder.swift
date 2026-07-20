import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Prepares a captured screenshot for a vision API: downscale to a sane cap,
/// then PNG-encode. Vision models bill by resized pixel dimensions (OpenAI
/// tiles at 512, Anthropic caps ~1568), so downscaling — not compression — is
/// what bounds token cost and latency. PNG keeps glyph edges crisp, which reads
/// more accurately than a lossy re-encode.
enum ImageEncoder {
    enum EncodeError: Error { case downscaleFailed, encodeFailed }

    /// Returns raw base64 (no `data:` prefix); the request builder wraps it per
    /// provider.
    static func pngBase64(_ image: CGImage, maxSide: Int) throws -> String {
        let scaled = try downscale(image, maxSide: maxSide)
        let data = try pngData(scaled)
        return data.base64EncodedString()
    }

    /// Redraw into a smaller bitmap when the longest side exceeds `maxSide`.
    /// Returns the original untouched when it already fits.
    static func downscale(_ image: CGImage, maxSide: Int) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide, longest > 0 else { return image }

        let scale = Double(maxSide) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw EncodeError.downscaleFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw EncodeError.downscaleFailed }
        return output
    }

    static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw EncodeError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EncodeError.encodeFailed }
        return data as Data
    }
}
