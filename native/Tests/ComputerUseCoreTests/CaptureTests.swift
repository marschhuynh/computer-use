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
}
