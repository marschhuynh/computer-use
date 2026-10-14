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

    func testRawActualWriteRejectionsAloneNegotiateEnhancedOrUnsupported() async throws {
        for rejection in [AXError.attributeUnsupported, .failure, .illegalArgument] {
            for enhanced in [AXError.success, rejection] {
                let raw = RawPreparationProbe()
                raw.set = { name in name == "AXManualAccessibility" ? rejection : enhanced }
                let driver = AXSnapshotPreparation.makeDriver(api: raw.api)
                XCTAssertEqual(try AXSnapshotPreparation.request(pid: 42, context: preparationContext(), driver: driver),
                               enhanced == .success ? .requestedEnhanced : .unsupported)
                XCTAssertEqual(raw.calls.names.filter { $0.hasPrefix("set:") },
                               ["set:AXManualAccessibility", "set:AXEnhancedUserInterface"])
                let prepared = RawPreparationProbe()
                prepared.set = raw.set
                try await AXSnapshotPreparation.prepare(pid: 42, context: preparationContext(),
                                                        driver: AXSnapshotPreparation.makeDriver(api: prepared.api))
                XCTAssertEqual(prepared.calls.names.filter { $0.hasPrefix("set:") }.count, 2)
            }
        }
    }

    func testRawTimeoutSetupNeverNegotiatesOrGetsSwallowed() async {
        for status in [AXError.attributeUnsupported, .failure, .illegalArgument, .cannotComplete,
                       .invalidUIElement, .apiDisabled, .notImplemented, .noValue] {
            for writeSetup in [false, true] {
                let raw = RawPreparationProbe()
                var setups = 0
                raw.timeout = { _ in
                    setups += 1
                    return setups == (writeSetup ? 2 : 1) ? status : .success
                }
                await assertRawPreparationFailure(status == .apiDisabled ? "PERMISSION_DENIED" : "NATIVE_FAILURE") {
                    try await AXSnapshotPreparation.prepare(pid: 42, context: preparationContext(),
                                                            driver: AXSnapshotPreparation.makeDriver(api: raw.api))
                }
                XCTAssertEqual(raw.calls.names.filter { $0 == "copy" }.count, writeSetup ? 1 : 0, "\(status)")
                XCTAssertEqual(raw.calls.names.filter { $0.hasPrefix("set:") }.count, 0, "\(status)")
                XCTAssertEqual(setups, writeSetup ? 2 : 1)
            }
        }
    }

    func testRawManualStateUsesStrictBooleanReadPolicy() async throws {
        for (status, value, expected) in [
            (AXError.attributeUnsupported, nil, nil), (.noValue, nil, nil),
            (.success, kCFBooleanTrue, true), (.success, kCFBooleanFalse, false)
        ] as [(AXError, CFTypeRef?, Bool?)] {
            let raw = RawPreparationProbe()
            raw.copy = { (status, value) }
            let driver = AXSnapshotPreparation.makeDriver(api: raw.api)
            XCTAssertEqual(try driver.readBool(42, "AXManualAccessibility", 0.25, preparationContext()), expected)
        }
        for (status, value) in [
            (AXError.success, nil), (.success, "wrong" as CFString),
            (.failure, nil), (.illegalArgument, nil), (.cannotComplete, nil),
            (.invalidUIElement, nil), (.apiDisabled, nil), (.notImplemented, nil)
        ] as [(AXError, CFTypeRef?)] {
            let raw = RawPreparationProbe()
            raw.copy = { (status, value) }
            await assertRawPreparationFailure(status == .apiDisabled ? "PERMISSION_DENIED" : "NATIVE_FAILURE") {
                try await AXSnapshotPreparation.prepare(pid: 42, context: preparationContext(),
                                                        driver: AXSnapshotPreparation.makeDriver(api: raw.api))
            }
            XCTAssertEqual(raw.calls.names.filter { $0.hasPrefix("set:") }, [])
        }
    }

    func testRawHardWritesAndDistinctiveThrownSetupStopPrepare() async {
        for status in [AXError.noValue, .cannotComplete, .invalidUIElement, .apiDisabled, .notImplemented] {
            let raw = RawPreparationProbe()
            raw.set = { _ in status }
            await assertRawPreparationFailure(status == .apiDisabled ? "PERMISSION_DENIED" : "NATIVE_FAILURE") {
                try await AXSnapshotPreparation.prepare(pid: 42, context: preparationContext(),
                                                        driver: AXSnapshotPreparation.makeDriver(api: raw.api))
            }
            XCTAssertEqual(raw.calls.names.filter { $0.hasPrefix("set:") }, ["set:AXManualAccessibility"])
        }
        for phase in ["create", "timeout"] {
            let raw = RawPreparationProbe()
            let expected = NativeFailure("NATIVE_FAILURE", "distinctive setup", details: ["origin": .string(phase)])
            if phase == "create" { raw.create = { throw expected } }
            else { raw.timeout = { _ in throw expected } }
            do {
                try await AXSnapshotPreparation.prepare(pid: 42, context: preparationContext(),
                                                        driver: AXSnapshotPreparation.makeDriver(api: raw.api))
                XCTFail("setup failure was swallowed")
            } catch let failure as NativeFailure {
                XCTAssertEqual(failure.code, expected.code)
                XCTAssertEqual(failure.message, expected.message)
                XCTAssertEqual(failure.details, expected.details)
            } catch { XCTFail("unexpected \(error)") }
            XCTAssertFalse(raw.calls.names.contains("copy"))
            XCTAssertEqual(raw.calls.names.filter { $0.hasPrefix("set:") }, [])
        }
    }

    func testPrepareValidatesTrustAndPIDBeforeAnyRawIPC() async {
        for pid in [0, -1, Int(Int32.max) + 1, Int.min, Int.max] {
            let raw = RawPreparationProbe()
            await assertRawPreparationFailure("NATIVE_FAILURE") {
                try await AXSnapshotPreparation.prepare(pid: pid, context: preparationContext(),
                                                        driver: AXSnapshotPreparation.makeDriver(api: raw.api))
            }
            XCTAssertEqual(raw.calls.names, ["trust"], "\(pid)")
        }
        let raw = RawPreparationProbe()
        raw.trusted = false
        await assertRawPreparationFailure("PERMISSION_DENIED") {
            try await AXSnapshotPreparation.prepare(pid: 42, context: preparationContext(),
                                                    driver: AXSnapshotPreparation.makeDriver(api: raw.api))
        }
        XCTAssertEqual(raw.calls.names, ["trust"])
        for cancelled in [false, true] {
            let raw = RawPreparationProbe()
            let context = preparationContext(timeoutMilliseconds: cancelled ? 1_000 : 0)
            if cancelled { context.cancel() }
            await assertRawPreparationFailure(cancelled ? "INTERRUPTED" : "TIMEOUT") {
                try await AXSnapshotPreparation.prepare(pid: 42, context: context,
                                                        driver: AXSnapshotPreparation.makeDriver(api: raw.api))
            }
            XCTAssertEqual(raw.calls.names, [])
        }
    }

    func testRawCreationConsumesBudgetAndEveryAttemptShrinksTimeout() throws {
        var now: UInt64 = 0
        let context = preparationContext(monotonicNow: { now })
        let raw = RawPreparationProbe()
        raw.create = { now += 100_000_000 }
        var caps: [Float] = []
        raw.timeout = { cap in caps.append(cap); return .success }
        raw.set = { _ in now = 850_000_000; return .attributeUnsupported }
        XCTAssertEqual(try AXSnapshotPreparation.request(pid: 42, context: context,
                         driver: AXSnapshotPreparation.makeDriver(api: raw.api)), .unsupported)
        XCTAssertEqual(caps.count, 2)
        XCTAssertEqual(caps[0], 0.25, accuracy: 0.000001)
        XCTAssertEqual(caps[1], 0.05, accuracy: 0.000001)
    }

    func testRawReadAndApplicationCreationConsumeBudgetBeforeBothWrites() async throws {
        var now: UInt64 = 0
        let context = preparationContext(monotonicNow: { now })
        let raw = RawPreparationProbe()
        raw.create = { now += 100_000_000 }
        var caps: [Float] = []
        raw.timeout = { caps.append($0); return .success }
        raw.copy = { now = 750_000_000; return (.noValue, nil) }
        raw.set = { _ in .attributeUnsupported }
        try await AXSnapshotPreparation.prepare(pid: 42, context: context,
            driver: AXSnapshotPreparation.makeDriver(api: raw.api))
        XCTAssertEqual(caps.count, 3)
        for (actual, expected) in zip(caps, [Float(0.25), 0.15, 0.05]) {
            XCTAssertEqual(actual, expected, accuracy: 0.000001)
        }
    }

    func testRawBlockedOperationsObserveCancellationAndDeadlineBeforeLaterIPC() async {
        for phase in ["create", "timeout", "copy", "set"] {
            for interruption in ["context", "task", "deadline"] {
                let entered = expectation(description: "\(phase) entered")
                let release = DispatchSemaphore(value: 0)
                defer { release.signal() }
                let now = PreparationNow()
                let context = preparationContext(monotonicNow: { now.value })
                let raw = RawPreparationProbe()
                let block = {
                    entered.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                }
                if phase == "create" { raw.create = block }
                if phase == "timeout" { raw.timeout = { _ in block(); return .attributeUnsupported } }
                if phase == "copy" { raw.copy = { block(); return (.noValue, nil) } }
                if phase == "set" { raw.set = { _ in block(); return .attributeUnsupported } }
                let work = Task.detached { () -> NativeFailure? in
                    do {
                        try await AXSnapshotPreparation.prepare(pid: 42, context: context,
                            driver: AXSnapshotPreparation.makeDriver(api: raw.api))
                        return nil
                    } catch let failure as NativeFailure { return failure }
                    catch { XCTFail("unexpected \(error)"); return nil }
                }
                await fulfillment(of: [entered], timeout: 2)
                if interruption == "task" { work.cancel() }
                else if interruption == "deadline" { now.value = context.deadline }
                else { context.cancel() }
                release.signal()
                let failure = await work.value
                XCTAssertEqual(failure?.code, interruption == "deadline" ? "TIMEOUT" : "INTERRUPTED")
                let names = raw.calls.names
                XCTAssertEqual(names.last, phase == "set" ? "set:AXManualAccessibility" : phase)
            }
        }
    }

    func testEnableDelayThresholdAndNoSleepOutcomes() async throws {
        for budget in [499, 500, 501, 2_000] {
            for state in [nil, false, true] as [Bool?] {
                var sleeps: [UInt64] = []
                let context = CommandContext(timeoutMilliseconds: budget, clock: NativeClock(
                    monotonicNow: { 0 }, wallNow: { Date(timeIntervalSince1970: 0) },
                    sleepNanoseconds: { sleeps.append($0) }))
                let raw = RawPreparationProbe()
                raw.copy = { state.map { (.success, $0 ? kCFBooleanTrue : kCFBooleanFalse) } ?? (.noValue, nil) }
                try await AXSnapshotPreparation.prepare(pid: 42, context: context,
                    driver: AXSnapshotPreparation.makeDriver(api: raw.api))
                XCTAssertEqual(sleeps, budget > 500 && state != true ? [250_000_000] : [])
            }
        }
        for deadline in [false, true] {
            var now: UInt64 = 0
            let cancellation = CommandCancellation()
            let context = CommandContext(timeoutMilliseconds: 1_000, clock: NativeClock(
                monotonicNow: { now }, wallNow: { Date(timeIntervalSince1970: 0) },
                sleepNanoseconds: { nanos in
                    XCTAssertEqual(nanos, 250_000_000)
                    if deadline { now = 1_000_000_000 } else { cancellation.cancel() }
                }), cancellation: cancellation)
            await assertRawPreparationFailure(deadline ? "TIMEOUT" : "INTERRUPTED") {
                try await AXSnapshotPreparation.prepare(pid: 42, context: context,
                    driver: AXSnapshotPreparation.makeDriver(api: RawPreparationProbe().api))
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
            (.notImplemented, "NATIVE_FAILURE"),
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
            (.notImplemented, "NATIVE_FAILURE"),
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

    func testPrepareSleeps250MillisecondsOnFirstManualEnableAndSkipsSleepWhenAlreadyEnabled() async throws {
        var sleptNanoseconds: [UInt64] = []
        var manualState: Bool? = false
        let driver = AXPreparationDriver(
            isTrusted: { true },
            write: { _, name, _, _ in
                if name == "AXManualAccessibility" {
                    manualState = true
                    return .success
                }
                return .attributeUnsupported
            },
            readBool: { _, name, _, _ in
                name == "AXManualAccessibility" ? manualState : nil
            }
        )
        let firstContext = CommandContext(
            timeoutMilliseconds: 2_000,
            clock: NativeClock(
                monotonicNow: { 0 },
                wallNow: { Date(timeIntervalSince1970: 0) },
                sleepNanoseconds: { sleptNanoseconds.append($0) }
            )
        )
        try await AXSnapshotPreparation.prepare(pid: 42, context: firstContext, driver: driver)
        XCTAssertEqual(sleptNanoseconds, [250_000_000])

        try await AXSnapshotPreparation.prepare(pid: 42, context: firstContext, driver: driver)
        XCTAssertEqual(sleptNanoseconds, [250_000_000])
    }

    func testPrepareToleratesActualWriteRejectionsWhileRethrowingPermission() async throws {
        let nonFatalDriver = AXPreparationDriver(
            isTrusted: { true },
            write: { _, _, _, _ in .failure }
        )
        try await AXSnapshotPreparation.prepare(
            pid: 42,
            context: preparationContext(),
            driver: nonFatalDriver
        )

        let untrustedDriver = AXPreparationDriver(
            isTrusted: { false },
            write: { _, _, _, _ in .success }
        )
        do {
            try await AXSnapshotPreparation.prepare(
                pid: 42,
                context: preparationContext(),
                driver: untrustedDriver
            )
            XCTFail("Expected PERMISSION_DENIED")
        } catch let failure as NativeFailure {
            XCTAssertEqual(failure.code, "PERMISSION_DENIED")
        }
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

private final class RawPreparationProbe {
    let calls = PreparationCalls()
    var trusted = true
    var create: () throws -> Void = {}
    var timeout: (Float) throws -> AXError = { _ in .success }
    var copy: () throws -> (status: AXError, value: CFTypeRef?) = { (.noValue, nil) }
    var set: (String) throws -> AXError = { _ in .success }

    var api: AXPreparationAPI {
        AXPreparationAPI(isTrusted: { self.calls.append("trust"); return self.trusted },
            createApplication: { _ in
                self.calls.append("create")
                try self.create()
                return AXUIElementCreateApplication(42) // Handle only; all IPC is injected.
            }, setMessagingTimeout: { _, cap in
                self.calls.append("timeout"); return try self.timeout(cap)
            }, copyAttribute: { _, _ in
                self.calls.append("copy"); return try self.copy()
            }, setAttribute: { _, name, value in
                XCTAssertTrue(CFEqual(value, kCFBooleanTrue))
                self.calls.append("set:" + name); return try self.set(name)
            })
    }
}

private final class PreparationNow {
    private let lock = NSLock()
    private var storage: UInt64 = 0
    var value: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

private func assertRawPreparationFailure(
    _ code: String, file: StaticString = #filePath, line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do { try await body(); XCTFail("expected " + code, file: file, line: line) }
    catch let failure as NativeFailure { XCTAssertEqual(failure.code, code, file: file, line: line) }
    catch { XCTFail("unexpected \(error)", file: file, line: line) }
}
