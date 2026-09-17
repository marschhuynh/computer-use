import CoreGraphics
import XCTest
@testable import ComputerUseCore

final class GeometryTests: XCTestCase {

    private func geo(
        window: WindowBounds,
        imageSize: CGSize,
        scale: CGFloat
    ) -> CaptureGeometry {
        CaptureGeometry(windowBounds: window, imageSize: imageSize, scale: scale)
    }

    // A 100x50 window rendered at scale 1 -> 100x50 image.
    func testScale1Identity() throws {
        let g = geo(
            window: WindowBounds(x: 100, y: 200, width: 100, height: 50),
            imageSize: CGSize(width: 100, height: 50),
            scale: 1
        )
        let p = try g.imageToScreen(CGPoint(x: 10, y: 20))
        XCTAssertEqual(p.x, 110, accuracy: 0.001)
        XCTAssertEqual(p.y, 220, accuracy: 0.001)
    }

    // A 100x50 window rendered at scale 2 -> 200x100 image; image px are 2x.
    func testScale2Retina() throws {
        let g = geo(
            window: WindowBounds(x: 100, y: 200, width: 100, height: 50),
            imageSize: CGSize(width: 200, height: 100),
            scale: 2
        )
        let p = try g.imageToScreen(CGPoint(x: 40, y: 30))
        XCTAssertEqual(p.x, 120, accuracy: 0.001)   // 100 + 40/2
        XCTAssertEqual(p.y, 215, accuracy: 0.001)   // 200 + 30/2
    }

    // Resized screenshot: image is half the logical window size.
    func testResizedImageTransform() throws {
        let g = geo(
            window: WindowBounds(x: 100, y: 200, width: 100, height: 50),
            imageSize: CGSize(width: 50, height: 25),   // downscaled 0.5x
            scale: 1
        )
        let p = try g.imageToScreen(CGPoint(x: 25, y: 12.5))
        XCTAssertEqual(p.x, 150, accuracy: 0.001)   // 100 + 25/0.5
        XCTAssertEqual(p.y, 225, accuracy: 0.001)
    }

    // Negative display origin (window on a secondary display left of main).
    func testNegativeDisplayOrigin() throws {
        let g = geo(
            window: WindowBounds(x: -1440, y: 100, width: 200, height: 100),
            imageSize: CGSize(width: 200, height: 100),
            scale: 1
        )
        let p = try g.imageToScreen(CGPoint(x: 50, y: 25))
        XCTAssertEqual(p.x, -1390, accuracy: 0.001)
        XCTAssertEqual(p.y, 125, accuracy: 0.001)
    }

    // Boundary: x == width is out of bounds (valid range is 0..<width).
    func testImageWidthBoundaryIsOutOfBounds() {
        let g = geo(
            window: WindowBounds(x: 0, y: 0, width: 100, height: 50),
            imageSize: CGSize(width: 100, height: 50),
            scale: 1
        )
        XCTAssertThrowsError(try g.imageToScreen(CGPoint(x: 100, y: 25))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "INVALID_ARGUMENT")
        }
        XCTAssertThrowsError(try g.imageToScreen(CGPoint(x: -1, y: 0)))
        XCTAssertThrowsError(try g.imageToScreen(CGPoint(x: 0, y: 50)))
    }

    func testNonFiniteImagePointRejected() {
        let g = geo(
            window: WindowBounds(x: 0, y: 0, width: 100, height: 50),
            imageSize: CGSize(width: 100, height: 50),
            scale: 1
        )
        XCTAssertThrowsError(try g.imageToScreen(CGPoint(x: CGFloat.nan, y: 0)))
        XCTAssertThrowsError(try g.imageToScreen(CGPoint(x: 0, y: CGFloat.infinity)))
    }

    // Inverse mapping is consistent.
    func testRoundTrip() throws {
        let g = geo(
            window: WindowBounds(x: 100, y: 200, width: 100, height: 50),
            imageSize: CGSize(width: 200, height: 100),
            scale: 2
        )
        let screen = try g.imageToScreen(CGPoint(x: 40, y: 30))
        let back = try g.screenToImage(screen)
        XCTAssertEqual(back.x, 40, accuracy: 0.001)
        XCTAssertEqual(back.y, 30, accuracy: 0.001)
    }
}
