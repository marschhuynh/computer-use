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

    private func displayTarget() -> ResolvedTarget {
        ResolvedTarget(
            identity: TargetIdentity(pid: 4242, launchDate: "2026-09-08T10:00:00.000Z", bundleId: nil, windowId: 77),
            title: "Display 77",
            bounds: WindowBounds(x: 0, y: 0, width: 2056, height: 1329),
            isDisplay: true
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

    func testLegacyCaptureRecordDecodesAsWindowTarget() throws {
        // A capture persisted before `isDisplay` existed must still decode —
        // the missing key defaults to false (window target).
        let json = """
        {
          "version": 1,
          "kind": "capture",
          "id": "123e4567-e89b-42d3-a456-426614174009",
          "createdAt": "2026-09-08T10:00:00.000Z",
          "expiresAt": "2026-09-08T10:10:00.000Z",
          "target": {
            "identity": {"pid": 42, "launchDate": "2026-09-08T10:00:00.000Z", "bundleId": "com.example.Editor", "windowId": 7},
            "title": "Doc",
            "bounds": {"x": 100, "y": 100, "width": 600, "height": 400}
          },
          "geometry": {"windowBounds": {"x": 100, "y": 100, "width": 600, "height": 400}, "imageSize": {"width": 1200, "height": 800}, "scale": 2},
          "path": "/tmp/capture.png",
          "invalidated": false
        }
        """
        let decoded = try JSONDecoder().decode(CaptureRecord.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.target.isDisplay)
        // Round-trip: encode always writes the flag.
        let reencoded = try JSONEncoder().encode(decoded.target)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        XCTAssertEqual(object["isDisplay"] as? Bool, false)
    }

    // MARK: - CaptureService

    func testScreenshotReturnsCaptureMetadata() async throws {
        let dir = temporaryStateRoot()
        let output = dir.appendingPathComponent("out.png").path
        let service = CaptureService(
            capturer: { target, _, _ in
                XCTAssertEqual(target.identity.windowId, 7)
                XCTAssertFalse(target.isDisplay)
                return CapturedImage(
                    pixelSize: CGSize(width: 1200, height: 800),
                    backingScale: 2,
                    pngData: Data([0x89, 0x50, 0x4E, 0x47])
                )
            },
            store: StateStore(rootURL: dir)
        )
        let reply = try await service.screenshot(
            target: target(), output: output, overwrite: false, native: false, context: context()
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
            capturer: { _, _, _ in CapturedImage(pixelSize: CGSize(width: 10, height: 10), backingScale: 1, pngData: Data()) },
            store: StateStore(rootURL: dir)
        )
        await XCTAssertThrowsErrorAsync {
            try await service.screenshot(target: target(), output: output, overwrite: false, native: false, context: context())
        }
    }

    func testScreenshotOverwriteFlagAllowsReplace() async throws {
        let dir = temporaryStateRoot()
        let output = dir.appendingPathComponent("replace.png").path
        FileManager.default.createFile(atPath: output, contents: Data([1, 2, 3]))
        let service = CaptureService(
            capturer: { _, _, _ in CapturedImage(pixelSize: CGSize(width: 10, height: 10), backingScale: 1, pngData: Data([9, 9, 9])) },
            store: StateStore(rootURL: dir)
        )
        _ = try await service.screenshot(target: target(), output: output, overwrite: true, native: false, context: context())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: output)), Data([9, 9, 9]))
    }

    func testScreenshotRejectsRelativeOutputPath() async throws {
        let service = CaptureService(
            capturer: { _, _, _ in CapturedImage(pixelSize: CGSize(width: 10, height: 10), backingScale: 1, pngData: Data()) },
            store: StateStore(rootURL: temporaryStateRoot())
        )
        await XCTAssertThrowsErrorAsync {
            try await service.screenshot(target: target(), output: "relative.png", overwrite: false, native: false, context: context())
        }
    }

    func testScreenshotDisplayTargetPersistsIsDisplayCapture() async throws {
        let dir = temporaryStateRoot()
        let output = dir.appendingPathComponent("display.png").path
        let service = CaptureService(
            capturer: { target, _, _ in
                XCTAssertTrue(target.isDisplay)
                XCTAssertEqual(target.identity.windowId, 77)
                return CapturedImage(
                    pixelSize: CGSize(width: 2056, height: 1329),
                    backingScale: 1,
                    pngData: Data([0x89, 0x50, 0x4E, 0x47])
                )
            },
            store: StateStore(rootURL: dir)
        )
        let reply = try await service.screenshot(
            target: displayTarget(), output: output, overwrite: false, native: false, context: context()
        )
        guard case let .object(data) = reply,
              case let .string(captureId) = data["captureId"] else {
            return XCTFail("missing captureId in \(reply)")
        }
        let rec = try StateStore(rootURL: dir).readCapture(id: captureId, context: context())
        XCTAssertTrue(rec.target.isDisplay)
        XCTAssertEqual(rec.target.identity.windowId, 77)
        XCTAssertEqual(rec.target.identity.pid, 4242)
    }

    // MARK: - NativeService .screenshot dispatch

    private func displayStubProvider() -> TargetResolverProvider {
        TargetResolverProvider(
            listApplications: {
                [ProcessMetadata(name: "Editor", pid: 42, launchDate: "2026-09-08T10:00:00.000Z", bundleId: "com.example.Editor")]
            },
            windowsForPID: { _, _ in
                [TargetWindow(
                    ax: AXWindowMetadata(
                        role: "AXWindow",
                        title: "Doc",
                        bounds: WindowBounds(x: 100, y: 100, width: 600, height: 400),
                        minimized: false
                    ),
                    cg: CGWindowMetadata(
                        id: 7,
                        title: "Doc",
                        bounds: WindowBounds(x: 100, y: 100, width: 600, height: 400),
                        onScreen: true,
                        minimized: false
                    )
                )]
            },
            listDisplays: {
                [
                    DisplayMetadata(
                        displayID: 77,
                        frame: WindowBounds(x: 0, y: 0, width: 2056, height: 1329),
                        width: 2056,
                        height: 1329
                    )
                ]
            }
        )
    }

    private func screenshotRequest(_ mutate: (inout [String: Any]) -> Void = { _ in }) -> WireRequest {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "command": "screenshot",
            "output": "/tmp/nuvin-cu-screenshot-test.png",
            "overwrite": true,
            "annotated": false,
            "native": false,
            "tree": ["maxDepth": 8, "maxElements": 500, "hintMode": "leafCompact"],
            "options": ["timeoutMs": 1_000, "cursor": "off"],
        ]
        mutate(&object)
        return WireRequest(command: .screenshot, object: object)
    }

    private func screenshotService(
        capturer: @escaping (ResolvedTarget) -> CapturedImage
    ) -> NativeService {
        NativeService(
            targetResolver: TargetResolver(provider: displayStubProvider()),
            store: StateStore(rootURL: temporaryStateRoot()),
            captureService: CaptureService(
                capturer: { target, _, _ in capturer(target) },
                store: StateStore(rootURL: temporaryStateRoot())
            )
        )
    }

    func testBareScreenshotResolvesPrimaryDisplay() async throws {
        var captured: ResolvedTarget?
        let service = screenshotService { target in
            captured = target
            return CapturedImage(
                pixelSize: CGSize(width: 2056, height: 1329),
                backingScale: 1,
                pngData: Data([0x89, 0x50, 0x4E, 0x47])
            )
        }
        let reply = await service.execute(screenshotRequest(), context: context())
        XCTAssertTrue(reply.ok, "expected success, got \(String(describing: reply.error))")
        let target = try XCTUnwrap(captured)
        XCTAssertTrue(target.isDisplay)
        XCTAssertEqual(target.identity.windowId, 77)
        XCTAssertEqual(target.bounds.width, 2056)
    }

    func testDisplayIndexSelectsDisplay() async throws {
        var captured: ResolvedTarget?
        let service = screenshotService { target in
            captured = target
            return CapturedImage(
                pixelSize: CGSize(width: 2056, height: 1329),
                backingScale: 1,
                pngData: Data([0x89, 0x50, 0x4E, 0x47])
            )
        }
        let reply = await service.execute(screenshotRequest { $0["display"] = 1 }, context: context())
        XCTAssertTrue(reply.ok, "expected success, got \(String(describing: reply.error))")
        XCTAssertEqual(captured?.identity.windowId, 77)
    }

    func testAnnotatedDisplayScreenshotIsInvalidArgument() async throws {
        let service = screenshotService { _ in
            XCTFail("capturer must not run for an annotated display target")
            return CapturedImage(pixelSize: .zero, backingScale: 1, pngData: Data())
        }
        let reply = await service.execute(screenshotRequest { $0["annotated"] = true }, context: context())
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, "INVALID_ARGUMENT")
    }

    func testTargetAndDisplayTogetherIsProtocolError() async throws {
        XCTAssertNil(WireRequest.decode([
            "schemaVersion": 1,
            "command": "screenshot",
            "target": ["pid": 42],
            "display": 1,
            "output": "/tmp/x.png",
            "overwrite": true,
            "annotated": false,
            "native": false,
            "tree": ["maxDepth": 8, "maxElements": 500, "hintMode": "leafCompact"],
            "options": ["timeoutMs": 1_000, "cursor": "off"],
        ]))
        let service = screenshotService { _ in
            XCTFail("capturer must not run when target and display are both present")
            return CapturedImage(pixelSize: .zero, backingScale: 1, pngData: Data())
        }
        let reply = await service.execute(
            screenshotRequest { $0["target"] = ["pid": 42]; $0["display"] = 1 },
            context: context()
        )
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, "PROTOCOL_ERROR")
    }

    // MARK: - display-capture spatial path (click/move/drag re-validation)

    /// A capture record for a display target persisted through StateStore, so
    /// resolveCapturePoint can read + re-validate it. Shares store+lock+input
    /// across the screenshot and the click so identity survives.
    private final class ClickRecorder: NativeInputDriver {
        var clicks: [CGPoint] = []
        func performAXAction(_ action: String, on element: LiveAXElement, context: CommandContext) throws {}
        func postKey(_ chord: String, to pid: Int, context: CommandContext) throws {}
        func postGlobalKey(_ chord: String, context: CommandContext) throws {}
        func postFocusedKey(_ chord: String, context: CommandContext) throws {}
        func postText(_ text: String, to pid: Int, context: CommandContext) throws {}
        func postFocusedText(_ text: String, context: CommandContext) throws {}
        func scroll(_ direction: String, amount: Int, at element: LiveAXElement?, point: CGPoint?, context: CommandContext) throws {}
        func click(at point: CGPoint, button: String, count: Int, context: CommandContext) throws {
            clicks.append(point)
        }
        func move(to point: CGPoint, context: CommandContext) throws {}
        func drag(from start: CGPoint, to end: CGPoint, context: CommandContext) throws {}
        func releaseHeldInputs() throws {}
    }

    private func displayClickService(
        displays: @escaping () -> [DisplayMetadata],
        recorder: ClickRecorder,
        store: StateStore,
        lock: DesktopLock
    ) -> NativeService {
        NativeService(
            desktopLock: lock,
            targetResolver: TargetResolver(provider: TargetResolverProvider(
                listApplications: { [] },
                windowsForPID: { _, _ in [] },
                listDisplays: displays
            )),
            store: store,
            input: NativeInput(driver: recorder)
        )
    }

    /// Seed a display-capture record directly through the store (bypasses the
    /// live capturer), then click a pixel. `displays` is the live listDisplays
    /// the resolver will re-validate against.
    private func seedDisplayCapture(
        store: StateStore,
        frame: WindowBounds = WindowBounds(x: 0, y: 0, width: 2056, height: 1329)
    ) throws -> String {
        let target = ResolvedTarget(
            identity: TargetIdentity(
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                launchDate: ProcessLaunchDate.format(ProcessInfo.processInfo.hostLaunchDate),
                bundleId: nil,
                windowId: 77
            ),
            title: "Display 77",
            bounds: frame,
            isDisplay: true
        )
        let record = CaptureRecord(
            id: "123e4567-e89b-42d3-a456-4266141740aa",
            createdAt: "2026-09-08T10:00:00.000Z",
            expiresAt: "2026-09-08T10:10:00.000Z",
            target: target,
            geometry: CaptureGeometry(windowBounds: frame, imageSize: CGSize(width: 2056, height: 1329), scale: 1),
            path: "/tmp/display-capture.png"
        )
        try store.writeCapture(record, context: context())
        return record.id
    }

    private func clickRequest(captureId: String) -> WireRequest {
        WireRequest(command: .click, object: [
            "schemaVersion": 1,
            "command": "click",
            "captureId": captureId,
            "point": ["x": 100, "y": 50],
            "button": "left",
            "count": 1,
            "options": ["timeoutMs": 1_000, "cursor": "off"],
        ])
    }

    func testClickOnDisplayCaptureResolvesScreenPoint() async throws {
        let dir = temporaryStateRoot()
        let store = StateStore(rootURL: dir)
        let lock = DesktopLock(rootURL: dir)
        let recorder = ClickRecorder()
        let frame = WindowBounds(x: 0, y: 0, width: 2056, height: 1329)
        let captureId = try seedDisplayCapture(store: store, frame: frame)
        let service = displayClickService(
            displays: { [DisplayMetadata(displayID: 77, frame: frame, width: 2056, height: 1329)] },
            recorder: recorder, store: store, lock: lock
        )
        let reply = await service.execute(clickRequest(captureId: captureId), context: context())
        XCTAssertTrue(reply.ok, "expected success, got \(String(describing: reply.error))")
        XCTAssertEqual(recorder.clicks, [CGPoint(x: 100, y: 50)])
    }

    func testClickOnDisplayCaptureStaleWhenDisplayGone() async throws {
        let dir = temporaryStateRoot()
        let store = StateStore(rootURL: dir)
        let lock = DesktopLock(rootURL: dir)
        let recorder = ClickRecorder()
        let captureId = try seedDisplayCapture(store: store)
        let service = displayClickService(
            displays: { [] }, // display no longer present
            recorder: recorder, store: store, lock: lock
        )
        let reply = await service.execute(clickRequest(captureId: captureId), context: context())
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, "STALE_CAPTURE")
        XCTAssertTrue(recorder.clicks.isEmpty)
    }

    func testClickOnDisplayCaptureStaleWhenFrameChanged() async throws {
        let dir = temporaryStateRoot()
        let store = StateStore(rootURL: dir)
        let lock = DesktopLock(rootURL: dir)
        let recorder = ClickRecorder()
        let captureId = try seedDisplayCapture(store: store)
        // Same displayID, but the frame moved (resolution/arrangement changed):
        // the recorded geometry no longer maps onto the screen.
        let moved = WindowBounds(x: 0, y: 0, width: 1024, height: 768)
        let service = displayClickService(
            displays: { [DisplayMetadata(displayID: 77, frame: moved, width: 1024, height: 768)] },
            recorder: recorder, store: store, lock: lock
        )
        let reply = await service.execute(clickRequest(captureId: captureId), context: context())
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, "STALE_CAPTURE")
        XCTAssertTrue(recorder.clicks.isEmpty)
    }
}
