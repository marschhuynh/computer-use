import XCTest
@testable import ComputerUseCore

final class CaptureTests: XCTestCase {

    private func context() -> CommandContext { discoveryContext() }

    private func target() -> ResolvedTarget {
        ResolvedTarget(
            identity: TargetIdentity(pid: 42, launchDate: "2026-09-08T10:00:00.000Z", bundleId: "com.example.Editor", windowId: 7),
            title: "Doc",
            bounds: WindowBounds(x: 100, y: 100, width: 600, height: 400)
        )
    }

    private func geometry() -> CaptureGeometry {
        CaptureGeometry(
            windowBounds: WindowBounds(x: 100, y: 100, width: 600, height: 400),
            imageSize: CGSize(width: 1200, height: 800),
            scale: 2
        )
    }

    // expiresAt must equal createdAt + snapshotLifetime (10 min) to satisfy the
    // store's lifetime invariant.
    private func record(
        id: String,
        invalidated: Bool = false,
        expiresAt: String = "2026-09-08T10:10:00.000Z"
    ) -> CaptureRecord {
        CaptureRecord(
            id: id,
            createdAt: "2026-09-08T10:00:00.000Z",
            expiresAt: expiresAt,
            target: target(),
            geometry: geometry(),
            path: "/tmp/capture.png",
            invalidated: invalidated
        )
    }

    func testCaptureRecordRoundTripsThroughStore() async throws {
        let store = StateStore(rootURL: temporaryStateRoot())
        let rec = record(id: "123e4567-e89b-42d3-a456-426614174000")
        try store.writeCapture(rec, context: context())
        let loaded = try store.readCapture(id: rec.id, context: context())
        XCTAssertEqual(loaded.id, rec.id)
        XCTAssertEqual(loaded.kind, "capture")
        XCTAssertEqual(loaded.target.identity.windowId, 7)
        XCTAssertEqual(loaded.geometry.imageSize.width, 1200)
        XCTAssertEqual(loaded.path, "/tmp/capture.png")
        XCTAssertFalse(loaded.invalidated)
    }

    func testReadingAnInvalidatedCaptureFails() async throws {
        let store = StateStore(rootURL: temporaryStateRoot())
        let rec = record(id: "123e4567-e89b-42d3-a456-426614174001")
        try store.writeCapture(rec, context: context())
        try store.invalidateRecords(for: rec.target.identity, context: context())
        XCTAssertThrowsError(try store.readCapture(id: rec.id, context: context())) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_CAPTURE")
        }
    }

    func testInvalidateRecordsCoversBothSnapshotsAndCaptures() async throws {
        let store = StateStore(rootURL: temporaryStateRoot())
        let capture = record(id: "123e4567-e89b-42d3-a456-426614174002")
        try store.writeCapture(capture, context: context())
        try store.invalidateRecords(for: capture.target.identity, context: context())
        XCTAssertThrowsError(try store.readCapture(id: capture.id, context: context()))
    }

    func testExpiredCaptureCannotBeRead() async throws {
        let store = StateStore(rootURL: temporaryStateRoot())
        let rec = record(id: "123e4567-e89b-42d3-a456-426614174003")
        // createdAt 2026-09-08T10:00:00Z -> expiresAt 10:10:00Z. Read with a wall
        // clock well past expiry -> STALE_CAPTURE.
        let writeContext = CommandContext(timeoutMilliseconds: 1_000, clock: NativeClock(
            monotonicNow: { 0 },
            wallNow: { Date(timeIntervalSince1970: 0) },
            sleepNanoseconds: { _ in }))
        try store.writeCapture(rec, context: writeContext)
        let readContext = CommandContext(timeoutMilliseconds: 1_000, clock: NativeClock(
            monotonicNow: { 0 },
            wallNow: { Date(timeIntervalSince1970: 3_000_000_000) }, // year 2065
            sleepNanoseconds: { _ in }))
        XCTAssertThrowsError(try store.readCapture(id: rec.id, context: readContext)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_CAPTURE")
        }
    }

    func testNonUuidCaptureIdRejected() async throws {
        let store = StateStore(rootURL: temporaryStateRoot())
        XCTAssertThrowsError(try store.readCapture(id: "not-a-uuid", context: context())) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_CAPTURE")
        }
    }

    // MARK: - CaptureService

    func testScreenshotReturnsCaptureMetadata() async throws {
        let dir = temporaryStateRoot()
        let output = dir.appendingPathComponent("out.png").path
        let service = CaptureService(
            capturer: { windowID, _ in
                XCTAssertEqual(windowID, 7)
                return CapturedImage(
                    pixelSize: CGSize(width: 1200, height: 800),
                    backingScale: 2,
                    pngData: Data([0x89, 0x50, 0x4E, 0x47])
                )
            },
            store: StateStore(rootURL: dir)
        )
        let reply = try await service.screenshot(
            target: target(), output: output, overwrite: false, context: context()
        )
        guard case let .object(data) = reply else { return XCTFail() }
        guard case let .string(captureId) = data["captureId"],
              case let .number(width) = data["width"],
              case let .number(height) = data["height"],
              case let .string(path) = data["path"] else {
            return XCTFail("missing capture fields in \(data)")
        }
        XCTAssertNotNil(UUID(uuidString: captureId))
        XCTAssertEqual(width, 1200)
        XCTAssertEqual(height, 800)
        XCTAssertEqual(path, output)
        // capture record persisted
        let rec = try StateStore(rootURL: dir).readCapture(id: captureId, context: context())
        XCTAssertEqual(rec.target.identity.windowId, 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output))
    }

    func testScreenshotRefusesToOverwriteWithoutFlag() async throws {
        let dir = temporaryStateRoot()
        let output = dir.appendingPathComponent("exists.png").path
        FileManager.default.createFile(atPath: output, contents: Data())
        let service = CaptureService(
            capturer: { _, _ in CapturedImage(pixelSize: CGSize(width: 10, height: 10), backingScale: 1, pngData: Data()) },
            store: StateStore(rootURL: dir)
        )
        await XCTAssertThrowsErrorAsync {
            try await service.screenshot(target: target(), output: output, overwrite: false, context: context())
        }
    }

    func testScreenshotOverwriteFlagAllowsReplace() async throws {
        let dir = temporaryStateRoot()
        let output = dir.appendingPathComponent("replace.png").path
        FileManager.default.createFile(atPath: output, contents: Data([1, 2, 3]))
        let service = CaptureService(
            capturer: { _, _ in CapturedImage(pixelSize: CGSize(width: 10, height: 10), backingScale: 1, pngData: Data([9, 9, 9])) },
            store: StateStore(rootURL: dir)
        )
        _ = try await service.screenshot(target: target(), output: output, overwrite: true, context: context())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: output)), Data([9, 9, 9]))
    }

    func testScreenshotRejectsRelativeOutputPath() async throws {
        let service = CaptureService(
            capturer: { _, _ in CapturedImage(pixelSize: CGSize(width: 10, height: 10), backingScale: 1, pngData: Data()) },
            store: StateStore(rootURL: temporaryStateRoot())
        )
        await XCTAssertThrowsErrorAsync {
            try await service.screenshot(target: target(), output: "relative.png", overwrite: false, context: context())
        }
    }
}
