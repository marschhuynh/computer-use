import ApplicationServices
import XCTest
@testable import ComputerUseCore

final class AXSnapshotPreparationTests: XCTestCase {
    func testEveryRequestChecksTrustAndNegotiatesWithoutPIDCaching() throws {
        var trustChecks = 0
        var calls: [String] = []
        let driver = AXPreparationDriver(isTrusted: {
            trustChecks += 1
            return true
        }, write: { _, name, _, _ in
            calls.append(name)
            return .success
        })
        for _ in 0..<2 {
            XCTAssertEqual(try AXSnapshotPreparation.request(pid: 42,
                context: preparationContext(), driver: driver), .requestedManual)
        }
        XCTAssertEqual(trustChecks, 2)
        XCTAssertEqual(calls, ["AXManualAccessibility", "AXManualAccessibility"])
    }

    func testMainQueueRemainsAvailableDuringDetachedFakeIPC() async throws {
        let entered = expectation(description: "detached fake IPC entered")
        let sentinel = expectation(description: "main queue sentinel")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let driver = AXPreparationDriver(isTrusted: { true }, write: { _, _, _, _ in
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            // The main queue, not a timer or cancellation, releases this fake call.
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return .success
        })
        let work = Task.detached {
            try AXSnapshotPreparation.request(pid: 42,
                context: preparationContext(), driver: driver)
        }
        await fulfillment(of: [entered], timeout: 2)
        DispatchQueue.main.async {
            sentinel.fulfill()
            release.signal()
        }
        await fulfillment(of: [sentinel], timeout: 2)
        let outcome = try await work.value
        XCTAssertEqual(outcome, .requestedManual)
    }

    func testCancellationDuringBlockedIPCStopsBeforeSuccessOrFallback() async {
        for cancelTask in [false, true] {
            for status in [AXError.success, .attributeUnsupported] {
                let context = preparationContext()
                let entered = expectation(description: "fake IPC entered")
                let release = DispatchSemaphore(value: 0)
                defer { release.signal() }
                let calls = PreparationCalls()
                let driver = AXPreparationDriver(isTrusted: { true }, write: { _, name, _, _ in
                    if calls.append(name) == 1 {
                        entered.fulfill()
                        XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                    }
                    return status
                })
                let work = Task.detached { () -> NativeFailure? in
                    do {
                        _ = try AXSnapshotPreparation.request(pid: 42,
                            context: context, driver: driver)
                        return nil
                    } catch let failure as NativeFailure {
                        return failure
                    } catch {
                        XCTFail("Unexpected error: \(error)")
                        return nil
                    }
                }
                await fulfillment(of: [entered], timeout: 2)
                if cancelTask { work.cancel() } else { context.cancel() }
                // Cancellation cannot release synchronous IPC; the fake must return first.
                release.signal()
                let failure = await work.value
                XCTAssertEqual(failure?.code, "INTERRUPTED")
                XCTAssertTrue(context.isCancelled)
                XCTAssertEqual(calls.names, ["AXManualAccessibility"])
            }
        }
    }

    func testThrownSetupFailureDoesNotNegotiateFallback() {
        var calls: [String] = []
        let failure = liveAXFailure(for: .attributeUnsupported)
        let driver = AXPreparationDriver(isTrusted: { true }, write: { _, name, _, _ in
            calls.append(name)
            // Simulates timeout-setup failure, not an attribute write's return status.
            throw failure
        })
        XCTAssertThrowsError(try AXSnapshotPreparation.request(pid: 42,
            context: preparationContext(), driver: driver)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, failure.code)
            XCTAssertEqual(($0 as? NativeFailure)?.message, failure.message)
        }
        XCTAssertEqual(calls, ["AXManualAccessibility"])
    }

    func testFallbackHardErrorsPropagateWithoutRetry() {
        for (status, code) in [
            (AXError.noValue, "NATIVE_FAILURE"),
            (.cannotComplete, "NATIVE_FAILURE"),
            (.invalidUIElement, "NATIVE_FAILURE"),
            (.failure, "NATIVE_FAILURE"),
            (.apiDisabled, "PERMISSION_DENIED")
        ] {
            var calls: [String] = []
            let driver = AXPreparationDriver(isTrusted: { true }, write: { _, name, _, _ in
                calls.append(name)
                return name == "AXManualAccessibility" ? .attributeUnsupported : status
            })
            XCTAssertThrowsError(try AXSnapshotPreparation.request(pid: 42,
                context: preparationContext(), driver: driver)) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, code)
            }
            XCTAssertEqual(calls, ["AXManualAccessibility", "AXEnhancedUserInterface"])
        }
    }

    func testPreCancellationStopsBeforeTrustOrWrite() {
        for timeout in [0, 1_000] {
            let context = preparationContext(timeoutMilliseconds: timeout)
            context.cancel()
            var trustChecks = 0
            var writes = 0
            let driver = AXPreparationDriver(isTrusted: {
                trustChecks += 1
                return true
            }, write: { _, _, _, _ in
                writes += 1
                return .success
            })
            XCTAssertThrowsError(try AXSnapshotPreparation.request(pid: 42,
                context: context, driver: driver)) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "INTERRUPTED")
            }
            XCTAssertEqual(trustChecks, 0)
            XCTAssertEqual(writes, 0)
        }
    }

    func testDeadlineExhaustedBetweenTrustAndWriteDoesNotIssueIPC() {
        var now: UInt64 = 0
        var advanceAfterRead = false
        let context = preparationContext(monotonicNow: {
            defer { if advanceAfterRead { now = 1_000_000_000 } }
            return now
        })
        var writes = 0
        let driver = AXPreparationDriver(isTrusted: {
            advanceAfterRead = true
            return true
        }, write: { _, _, _, _ in
            writes += 1
            return .success
        })
        XCTAssertThrowsError(try AXSnapshotPreparation.request(pid: 42,
            context: context, driver: driver)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "TIMEOUT")
        }
        XCTAssertEqual(writes, 0)
    }

    func testCancellationDuringTrustCheckStopsBeforeWriteEvenWhenUntrusted() {
        for trusted in [true, false] {
            let context = preparationContext()
            var writes = 0
            let driver = AXPreparationDriver(isTrusted: {
                context.cancel()
                return trusted
            }, write: { _, _, _, _ in
                writes += 1
                return .success
            })
            XCTAssertThrowsError(try AXSnapshotPreparation.request(pid: 42,
                context: context, driver: driver)) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "INTERRUPTED")
            }
            XCTAssertEqual(writes, 0)
        }
    }

    func testDeadlineExhaustedDuringWriteStopsBeforeSuccessOrFallback() {
        for status in [AXError.success, .attributeUnsupported, .failure] {
            var now: UInt64 = 0
            let context = preparationContext(monotonicNow: { now })
            var calls: [String] = []
            let driver = AXPreparationDriver(isTrusted: { true }, write: { _, name, _, _ in
                calls.append(name)
                now = context.deadline
                return status
            })
            XCTAssertThrowsError(try AXSnapshotPreparation.request(pid: 42,
                context: context, driver: driver)) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "TIMEOUT")
            }
            XCTAssertEqual(calls, ["AXManualAccessibility"])
        }
    }

    func testExhaustedDeadlineStopsBeforeTrustOrWrite() {
        var trustChecks = 0
        var writes = 0
        let driver = AXPreparationDriver(isTrusted: {
            trustChecks += 1
            return true
        }, write: { _, _, _, _ in
            writes += 1
            return .success
        })
        XCTAssertThrowsError(try AXSnapshotPreparation.request(pid: 42,
            context: preparationContext(timeoutMilliseconds: 0), driver: driver)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "TIMEOUT")
        }
        XCTAssertEqual(trustChecks, 0)
        XCTAssertEqual(writes, 0)
    }

    func testEachAttemptRecomputesThe250MillisecondCapAgainstRemainingBudget() throws {
        var now: UInt64 = 0
        let context = preparationContext(monotonicNow: { now })
        var timeouts: [Float] = []
        let driver = AXPreparationDriver(isTrusted: { true }, write: { _, _, timeout, received in
            XCTAssertTrue(received === context)
            timeouts.append(timeout)
            now = 950_000_000
            return .attributeUnsupported
        })
        XCTAssertEqual(try AXSnapshotPreparation.request(pid: 42,
            context: context, driver: driver), .unsupported)
        XCTAssertEqual(timeouts, [Float(0.25), Float(0.05)])
    }

    func testInvalidPIDFailsBeforeWriting() {
        for pid in [0, -1, Int(Int32.max) + 1, Int.min, Int.max] {
            var writes = 0
            let driver = AXPreparationDriver(isTrusted: { true }, write: { _, _, _, _ in
                writes += 1
                return .success
            })
            XCTAssertThrowsError(try AXSnapshotPreparation.request(pid: pid,
                context: preparationContext(), driver: driver)) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "NATIVE_FAILURE")
                XCTAssertEqual(($0 as? NativeFailure)?.message, "Invalid accessibility process")
            }
            XCTAssertEqual(writes, 0, "\(pid)")
        }
    }

    func testUntrustedDriverFailsBeforeWriting() {
        var trustChecks = 0
        var writes = 0
        let driver = AXPreparationDriver(isTrusted: {
            trustChecks += 1
            return false
        }, write: { _, _, _, _ in
            writes += 1
            return .success
        })
        XCTAssertThrowsError(try AXSnapshotPreparation.request(pid: 42,
            context: preparationContext(), driver: driver)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "PERMISSION_DENIED")
        }
        XCTAssertEqual(trustChecks, 1)
        XCTAssertEqual(writes, 0)
    }

    func testManualErrorsAreNotCapabilityFallbacks() {
        for (status, code) in [
            (AXError.noValue, "NATIVE_FAILURE"),
            (.cannotComplete, "NATIVE_FAILURE"),
            (.invalidUIElement, "NATIVE_FAILURE"),
            (.failure, "NATIVE_FAILURE"),
            (.apiDisabled, "PERMISSION_DENIED")
        ] {
            var calls: [String] = []
            let driver = AXPreparationDriver(isTrusted: { true }, write: { _, name, _, _ in
                calls.append(name)
                return status
            })
            XCTAssertThrowsError(try AXSnapshotPreparation.request(pid: 42,
                context: preparationContext(), driver: driver), "\(status)") {
                XCTAssertEqual(($0 as? NativeFailure)?.code, code, "\(status)")
                XCTAssertEqual(($0 as? NativeFailure)?.message, liveAXFailure(for: status).message)
            }
            XCTAssertEqual(calls, ["AXManualAccessibility"], "\(status)")
        }
    }

    func testBothUnsupportedReturnsUnsupportedAfterTwoWrites() throws {
        var calls: [String] = []
        let driver = AXPreparationDriver(isTrusted: { true }, write: { _, name, _, _ in
            calls.append(name)
            return .attributeUnsupported
        })
        XCTAssertEqual(try AXSnapshotPreparation.request(pid: 42,
            context: preparationContext(), driver: driver), .unsupported)
        XCTAssertEqual(calls, ["AXManualAccessibility", "AXEnhancedUserInterface"])
    }

    func testManualSuccessDoesNotWriteLegacyAttribute() throws {
        var calls: [String] = []
        let driver = AXPreparationDriver(isTrusted: { true }, write: { _, name, _, _ in
            calls.append(name)
            return .success
        })
        XCTAssertEqual(try AXSnapshotPreparation.request(pid: 42,
            context: preparationContext(), driver: driver), .requestedManual)
        XCTAssertEqual(calls, ["AXManualAccessibility"])
    }

    func testFallbackOnlyAfterUnsupported() throws {
        var calls: [String] = []
        let driver = AXPreparationDriver(isTrusted: { true }, write: { pid, name, timeout, _ in
            XCTAssertEqual(pid, 42) // Fake closure only; never sent to live AX.
            XCTAssertGreaterThan(timeout, 0)
            XCTAssertLessThanOrEqual(timeout, Float(0.25))
            calls.append(name)
            return name == "AXManualAccessibility" ? .attributeUnsupported : .success
        })
        let result = try AXSnapshotPreparation.request(pid: 42,
            context: preparationContext(), driver: driver)
        XCTAssertEqual(result, .requestedEnhanced)
        XCTAssertEqual(calls, ["AXManualAccessibility", "AXEnhancedUserInterface"])
    }
}

private func preparationContext(
    timeoutMilliseconds: Int = 1_000,
    monotonicNow: @escaping () -> UInt64 = { 0 }
) -> CommandContext {
    CommandContext(
        timeoutMilliseconds: timeoutMilliseconds,
        clock: NativeClock(
            monotonicNow: monotonicNow,
            wallNow: { Date(timeIntervalSince1970: 0) },
            sleepNanoseconds: { _ in XCTFail("Preparation must not sleep") }
        )
    )
}

private final class PreparationCalls {
    private let lock = NSLock()
    private var storage: [String] = []

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage.append(name)
        return storage.count
    }
}
