import XCTest
import CoreGraphics
@testable import DuoTranslator

final class ImageEncoderTests: XCTestCase {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testDownscaleCapsLongestSide() throws {
        let image = makeImage(width: 4000, height: 2000)
        let scaled = try ImageEncoder.downscale(image, maxSide: 1600)
        XCTAssertEqual(scaled.width, 1600)
        XCTAssertEqual(scaled.height, 800) // aspect ratio preserved
    }

    func testDownscaleLeavesSmallImageUntouched() throws {
        let image = makeImage(width: 800, height: 600)
        let scaled = try ImageEncoder.downscale(image, maxSide: 1600)
        XCTAssertEqual(scaled.width, 800)
        XCTAssertEqual(scaled.height, 600)
    }

    func testPngBase64IsNonEmptyAndDecodable() throws {
        let image = makeImage(width: 100, height: 100)
        let base64 = try ImageEncoder.pngBase64(image, maxSide: 1600)
        XCTAssertFalse(base64.isEmpty)
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        // PNG magic number.
        XCTAssertEqual([UInt8](data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}
