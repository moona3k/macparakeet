import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MacParakeetCore

final class ThumbnailImageDecoderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbnail-decoder-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDownsamplesLongestSideToMaxPixelSize() throws {
        let url = try writeJPEG(width: 1280, height: 720)

        let image = try XCTUnwrap(ThumbnailImageDecoder.image(contentsOf: url, maxPixelSize: 800))

        XCTAssertEqual(image.width, 800)
        XCTAssertEqual(image.height, 450)
    }

    func testDoesNotUpscaleSmallImages() throws {
        let url = try writeJPEG(width: 320, height: 180)

        let image = try XCTUnwrap(ThumbnailImageDecoder.image(contentsOf: url, maxPixelSize: 800))

        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 180)
    }

    func testReturnsNilForMissingOrUndecodableFiles() throws {
        let missing = tempDir.appendingPathComponent("missing.jpg")
        XCTAssertNil(ThumbnailImageDecoder.image(contentsOf: missing, maxPixelSize: 800))

        let corrupt = tempDir.appendingPathComponent("corrupt.jpg")
        try Data("not an image".utf8).write(to: corrupt)
        XCTAssertNil(ThumbnailImageDecoder.image(contentsOf: corrupt, maxPixelSize: 800))
    }

    private func writeJPEG(width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let url = tempDir.appendingPathComponent("\(UUID().uuidString).jpg")
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
