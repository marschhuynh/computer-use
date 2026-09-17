import CoreGraphics
import Foundation

/// Maps image-pixel coordinates from a saved capture to screen coordinates in
/// the captured window's coordinate space, and back. All math is pure and
/// deterministic — the backing scale is taken from the capture metadata, never
/// estimated from whole-desktop dimensions.
public struct CaptureGeometry: Equatable {
    /// Screen-space bounds of the captured window at capture time.
    public let windowBounds: WindowBounds
    /// Pixel dimensions of the saved image.
    public let imageSize: CGSize
    /// Backing scale of the capture (image pixels per logical window point).
    public let scale: CGFloat

    public init(windowBounds: WindowBounds, imageSize: CGSize, scale: CGFloat) {
        self.windowBounds = windowBounds
        self.imageSize = imageSize
        self.scale = scale
    }

    /// image px per logical window point, derived from the actual image size
    /// vs. the window's logical size — handles Retina scale *and* any resize.
    private var pixelsPerWindowX: CGFloat {
        imageSize.width / CGFloat(windowBounds.width)
    }
    private var pixelsPerWindowY: CGFloat {
        imageSize.height / CGFloat(windowBounds.height)
    }

    /// Map an image pixel to a screen point. Throws INVALID_ARGUMENT on
    /// non-finite or out-of-bounds input (valid range is 0..<width / 0..<height).
    public func imageToScreen(_ point: CGPoint) throws -> CGPoint {
        guard point.x.isFinite, point.y.isFinite else {
            throw NativeFailure("INVALID_ARGUMENT", "Coordinate must be finite")
        }
        guard point.x >= 0, point.y >= 0,
              point.x < imageSize.width, point.y < imageSize.height else {
            throw NativeFailure("INVALID_ARGUMENT", "Coordinate is outside the captured image")
        }
        return CGPoint(
            x: CGFloat(windowBounds.x) + point.x / pixelsPerWindowX,
            y: CGFloat(windowBounds.y) + point.y / pixelsPerWindowY
        )
    }

    /// Inverse of `imageToScreen`. Rejects non-finite input.
    public func screenToImage(_ point: CGPoint) throws -> CGPoint {
        guard point.x.isFinite, point.y.isFinite else {
            throw NativeFailure("INVALID_ARGUMENT", "Coordinate must be finite")
        }
        return CGPoint(
            x: (point.x - CGFloat(windowBounds.x)) * pixelsPerWindowX,
            y: (point.y - CGFloat(windowBounds.y)) * pixelsPerWindowY
        )
    }
}
