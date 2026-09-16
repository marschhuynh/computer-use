import Dispatch
import Foundation

public struct NativeClock {
    public let monotonicNow: () -> UInt64
    public let wallNow: () -> Date
    public let sleepNanoseconds: (UInt64) async throws -> Void

    public init(
        monotonicNow: @escaping () -> UInt64,
        wallNow: @escaping () -> Date,
        sleepNanoseconds: @escaping (UInt64) async throws -> Void
    ) {
        self.monotonicNow = monotonicNow
        self.wallNow = wallNow
        self.sleepNanoseconds = sleepNanoseconds
    }

    public static let system = NativeClock(
        monotonicNow: { DispatchTime.now().uptimeNanoseconds },
        wallNow: Date.init,
        sleepNanoseconds: { try await Task.sleep(nanoseconds: $0) }
    )
}

public final class CommandCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let pending = handlers
        handlers.removeAll()
        lock.unlock()
        pending.forEach { $0() }
    }

    public func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
        } else {
            handlers.append(handler)
            lock.unlock()
        }
    }
}

public final class CommandContext {
    public let deadline: UInt64
    public let clock: NativeClock
    public let cancellation: CommandCancellation

    public init(
        timeoutMilliseconds: Int,
        clock: NativeClock = .system,
        cancellation: CommandCancellation = CommandCancellation()
    ) {
        self.clock = clock
        self.cancellation = cancellation
        deadline = Self.deadlineNanoseconds(
            now: clock.monotonicNow(),
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    public var wallNow: Date { clock.wallNow() }

    public var remainingNanoseconds: UInt64 {
        let now = clock.monotonicNow()
        return now >= deadline ? 0 : deadline - now
    }

    public var isCancelled: Bool { cancellation.isCancelled }

    public func cancel() { cancellation.cancel() }

    public func onCancel(_ handler: @escaping () -> Void) {
        cancellation.onCancel(handler)
    }

    public func check() throws {
        try checkInterruption()
        if clock.monotonicNow() >= deadline {
            try checkInterruption()
            throw NativeFailure("TIMEOUT", "Desktop operation deadline expired")
        }
    }

    func checkLockWait(observedContention: Bool) throws {
        try checkInterruption()
        guard remainingNanoseconds == 0 else { return }
        try checkInterruption()
        if observedContention {
            throw NativeFailure("BUSY", "Another desktop operation is in progress")
        }
        throw NativeFailure("TIMEOUT", "Desktop operation deadline expired")
    }

    public func sleep(nanoseconds requested: UInt64) async throws {
        try check()
        if requested == 0 { return }
        let duration = min(requested, remainingNanoseconds)
        guard duration > 0 else {
            try check()
            return
        }
        do {
            try await withTaskCancellationHandler(operation: {
                try await clock.sleepNanoseconds(duration)
            }, onCancel: {
                self.cancellation.cancel()
            })
        } catch is CancellationError {
            cancellation.cancel()
            throw NativeFailure("INTERRUPTED", "Interrupted")
        }
        try check()
    }

    static func deadlineNanoseconds(now: UInt64, timeoutMilliseconds: Int) -> UInt64 {
        let milliseconds = UInt64(max(0, timeoutMilliseconds))
        let (increment, multiplied) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        if multiplied { return UInt64.max }
        let (value, added) = now.addingReportingOverflow(increment)
        return added ? UInt64.max : value
    }

    private func checkInterruption() throws {
        if cancellation.isCancelled {
            throw NativeFailure("INTERRUPTED", "Interrupted")
        }
        if Task.isCancelled {
            cancellation.cancel()
            throw NativeFailure("INTERRUPTED", "Interrupted")
        }
    }
}
