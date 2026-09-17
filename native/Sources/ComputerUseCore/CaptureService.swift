import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// The pixels + metadata a window capture produced. `pngData` is the encoded
/// image; `pixelSize`/`backingScale` describe it for geometry transforms.
public struct CapturedImage {
    public let pixelSize: CGSize
    public let backingScale: CGFloat
    public let pngData: Data

    public init(pixelSize: CGSize, backingScale: CGFloat, pngData: Data) {
        self.pixelSize = pixelSize
        self.backingScale = backingScale
        self.pngData = pngData
    }
}

/// Window-only screenshot capture. The `capturer` is injected so tests never
/// touch ScreenCaptureKit; the live path captures exactly one `SCWindow`.
public final class CaptureService {
    /// (windowID, context) -> captured image.
    public typealias Capturer = (Int, CommandContext) async throws -> CapturedImage

    private let capturer: Capturer
    private let store: StateStore

    public init(
        capturer: @escaping Capturer,
        store: StateStore = StateStore()
    ) {
        self.capturer = capturer
        self.store = store
    }

    /// Capture `target`'s window to an absolute `output` path, publish it
    /// atomically (no overwrite unless `overwrite`), persist a `capture` record,
    /// and return the reply `data` payload.
    public func screenshot(
        target: ResolvedTarget,
        output: String,
        overwrite: Bool,
        context: CommandContext,
        annotations: [(ref: Int, bounds: WindowBounds)] = []
    ) async throws -> JSONValue {
        try context.check()
        guard output.hasPrefix("/") else {
            throw NativeFailure("INVALID_ARGUMENT", "--output must be an absolute path")
        }
        let outputURL = URL(fileURLWithPath: output)
        if !overwrite, FileManager.default.fileExists(atPath: output) {
            throw NativeFailure("INVALID_ARGUMENT", "--output exists; pass --overwrite to replace it")
        }

        let captured = try await capturer(target.identity.windowId, context)
        try context.check()
        guard captured.pixelSize.width > 0, captured.pixelSize.height > 0 else {
            throw NativeFailure("NATIVE_FAILURE", "Window capture produced an empty image")
        }

        let geometry = CaptureGeometry(
            windowBounds: target.bounds,
            imageSize: captured.pixelSize,
            scale: captured.backingScale
        )

        // Annotate ref-hint badges onto the captured image before publishing,
        // so the saved PNG carries the markers agents read back.
        let pngData: Data
        if annotations.isEmpty {
            pngData = captured.pngData
        } else {
            guard let annotatedData = annotate(captured.pngData, annotations: annotations, geometry: geometry) else {
                throw NativeFailure("NATIVE_FAILURE", "Unable to annotate screenshot")
            }
            pngData = annotatedData
        }

        // Publish the PNG atomically via a same-dir temp file + rename.
        try publishAtomically(pngData, to: outputURL, overwrite: overwrite)
        try context.check()

        // Derive both timestamps from one instant — validLifetime requires
        // expiresAt's sub-second component to equal createdAt's exactly.
        let created = context.wallNow
        let record = CaptureRecord(
            id: UUID().uuidString.lowercased(),
            createdAt: timestamp(created),
            expiresAt: timestamp(created.addingTimeInterval(snapshotLifetime)),
            target: target,
            geometry: geometry,
            path: output
        )
        try store.writeCapture(record, context: context)
        try context.check()

        return .object([
            "captureId": .string(record.id),
            "target": targetJSON(target),
            "path": .string(output),
            "width": .number(Double(captured.pixelSize.width)),
            "height": .number(Double(captured.pixelSize.height)),
            "createdAt": .string(record.createdAt),
            "expiresAt": .string(record.expiresAt),
        ])
    }

    /// Atomic publication: write a private temp file in the destination dir,
    /// fsync, then rename. No partial files are left at `output` on failure.
    private func publishAtomically(_ data: Data, to url: URL, overwrite: Bool) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".tmp.\(UUID().uuidString).png")
        do {
            try data.write(to: temporary, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw NativeFailure("NATIVE_FAILURE", "Unable to write screenshot output")
        }
        if !overwrite {
            // Guard the final move: rename would clobber an existing file.
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: temporary)
                throw NativeFailure("INVALID_ARGUMENT", "--output exists; pass --overwrite to replace it")
            }
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            // No prior file: replaceItemAt fails; fall back to move for a fresh path.
            do { try FileManager.default.moveItem(at: temporary, to: url) }
            catch {
                try? FileManager.default.removeItem(at: temporary)
                throw NativeFailure("NATIVE_FAILURE", "Unable to publish screenshot output")
            }
        }
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private func targetJSON(_ target: ResolvedTarget) -> JSONValue {
    .object([
        "pid": .number(Double(target.identity.pid)),
        "launchDate": .string(target.identity.launchDate),
        "bundleId": target.identity.bundleId.map(JSONValue.string) ?? .null,
        "windowId": .number(Double(target.identity.windowId)),
        "title": .string(target.title),
        "bounds": .object([
            "x": .number(target.bounds.x),
            "y": .number(target.bounds.y),
            "width": .number(target.bounds.width),
            "height": .number(target.bounds.height),
        ]),
    ])
}

#if canImport(ScreenCaptureKit)
/// Live ScreenCaptureKit window capture — window-only, cursor excluded, no
/// desktop fallback. Verified against the macOS-14 SDK surface at Stage E gate.
public func liveWindowCapture(windowID: Int, context: CommandContext) async throws -> CapturedImage {
    guard CGPreflightScreenCaptureAccess() else {
        throw NativeFailure("PERMISSION_DENIED", "Screen Recording access is unavailable")
    }
    try context.check()
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    try context.check()
    guard let window = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) else {
        throw NativeFailure("TARGET_NOT_FOUND", "Window is not capturable")
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    configuration.showsCursor = false
    // Pin the output to the window's own frame rendered at the containing
    // display's backing scale. Without explicit dimensions SCK can return a
    // display-sized canvas with the window letterboxed into it, which would
    // offset every image→screen coordinate transform.
    let scale = await displayScale(containing: window.frame)
    configuration.width = Int((window.frame.width * scale).rounded())
    configuration.height = Int((window.frame.height * scale).rounded())
    configuration.sourceRect = CGRect(origin: .zero, size: window.frame.size)
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    try context.check()
    guard let data = pngEncode(image) else {
        throw NativeFailure("NATIVE_FAILURE", "Window capture produced no image data")
    }
    return CapturedImage(
        pixelSize: CGSize(width: image.width, height: image.height),
        backingScale: CGFloat(image.width) / CGFloat(window.frame.width),
        pngData: data
    )
}

/// `SCScreenshotManager` can return a `CGImage` whose pixel format ImageIO
/// won't encode directly (destination `Finalize` fails). Draw it into a
/// plain RGBA bitmap context first so the encode always has a supported
/// source.
/// Backing scale (px per point) of the display containing the window's frame.
/// `NSScreen` frame is bottom-left origin; `SCWindow.frame` is top-left, so we
/// flip Y before containment testing. Runs on the main actor for AppKit.
@MainActor
private func displayScale(containing windowFrame: CGRect) -> CGFloat {
    #if canImport(AppKit)
    guard let primary = NSScreen.screens.first else { return 1 }
    let primaryHeight = primary.frame.height
    // Convert the window's top-left-origin frame to AppKit's bottom-left origin.
    let flipped = CGRect(
        x: windowFrame.minX,
        y: primaryHeight - windowFrame.maxY,
        width: windowFrame.width,
        height: windowFrame.height
    )
    for screen in NSScreen.screens where screen.frame.intersects(flipped) {
        return screen.backingScaleFactor
    }
    #endif
    return 1
}

private func pngEncode(_ image: CGImage) -> Data? {
    let width = image.width, height = image.height
    guard width > 0, height > 0 else { return nil }
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let flat = context.makeImage() else { return nil }
    let buffer = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        buffer as CFMutableData, "public.png" as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(destination, flat, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return buffer as Data
}

/// Overlay a numbered ref-hint badge at each element's top-left corner so the
/// saved PNG maps pixels back to snapshot refs (Vimium-style). `bounds` are in
/// screen space; `geometry` maps them into image pixels.
private func annotate(
    _ pngData: Data,
    annotations: [(ref: Int, bounds: WindowBounds)],
    geometry: CaptureGeometry
) -> Data? {
    guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // CGContext is bottom-left origin; flip so image y grows downward like the
    // captured pixels, then badges land on their elements.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)

    let badgeFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 11 * geometry.scale, nil)
    for annotation in annotations {
        guard let bounds = annotation.bounds as WindowBounds? else { continue }
        let center = CGPoint(
            x: CGFloat(bounds.x) + CGFloat(bounds.width) / 2,
            y: CGFloat(bounds.y) + CGFloat(bounds.height) / 2
        )
        guard let imagePoint = try? geometry.screenToImage(center) else { continue }
        guard imagePoint.x >= 0, imagePoint.y >= 0,
              imagePoint.x < CGFloat(width), imagePoint.y < CGFloat(height) else { continue }

        let text = "\(annotation.ref)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let textBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let pad: CGFloat = 3 * geometry.scale
        let badgeW = textBounds.width + pad * 2
        let badgeH = textBounds.height + pad * 2
        let badgeRect = CGRect(
            x: imagePoint.x - badgeW / 2,
            y: imagePoint.y - badgeH / 2,
            width: badgeW, height: badgeH
        )
        // Badge: filled rounded rect + white ref number.
        context.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 0.92))
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 3 * geometry.scale, cornerHeight: 3 * geometry.scale, transform: nil)
        context.addPath(path)
        context.fillPath()
        // Text is drawn in the flipped space; flip it back for the glyph run.
        context.saveGState()
        context.translateBy(x: badgeRect.minX + pad, y: badgeRect.minY + pad)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: 0, y: -(textBounds.height + pad * 0))
        CTLineDraw(line, context)
        context.restoreGState()
    }
    guard let flat = context.makeImage() else { return nil }
    return pngEncode(flat)
}
#endif
