import Darwin
import Dispatch
import Foundation

/// Request-line cap: 2 MiB. Text payloads are separately capped at 1 MiB in the
/// CLI, so a request line stays well under this bound.
public let maximumRequestLineBytes = 2 * 1_048_576

public enum BoundedLineReadResult: Equatable {
    case awaitingInput
    case line(Data)
    case invalid
    case emptyEndOfFile
}

public struct BoundedLineReader {
    private let maximumBytes: Int
    private var buffer = Data()
    private var finished = false

    public init(maximumBytes: Int = maximumRequestLineBytes) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
    }

    public var bufferedByteCount: Int { buffer.count }

    public mutating func consume(_ chunk: Data, endOfFile: Bool = false) -> BoundedLineReadResult {
        guard !finished else { return .invalid }

        if let newline = chunk.firstIndex(of: 0x0a) {
            let lineFragment = chunk[..<newline]
            guard lineFragment.count <= maximumBytes - buffer.count else {
                finished = true
                return .invalid
            }
            buffer.append(contentsOf: lineFragment)
            finished = true
            return .line(buffer)
        }

        guard chunk.count <= maximumBytes - buffer.count else {
            finished = true
            return .invalid
        }
        buffer.append(chunk)
        if endOfFile {
            finished = true
            return buffer.isEmpty ? .emptyEndOfFile : .invalid
        }
        return .awaitingInput
    }
}

public final class HostSession {
    public typealias Work = (
        _ context: CommandContext,
        _ completion: @escaping (WireReply) -> Void
    ) -> Task<Void, Never>

    private enum State {
        case ready
        case running
        case cancelling
        case finished
    }

    private let lock = NSLock()
    private let context: CommandContext
    private let work: Work
    private let onReply: (WireReply) -> Void
    private let onShutdown: () -> Void
    private var state = State.ready
    private var task: Task<Void, Never>?

    public init(
        context: CommandContext,
        work: @escaping Work,
        onReply: @escaping (WireReply) -> Void,
        onShutdown: @escaping () -> Void
    ) {
        self.context = context
        self.work = work
        self.onReply = onReply
        self.onShutdown = onShutdown
    }

    public func start() {
        lock.lock()
        guard state == .ready else {
            lock.unlock()
            return
        }
        state = .running
        lock.unlock()

        let started = work(context) { [weak self] reply in
            self?.workDidFinish(reply)
        }

        lock.lock()
        switch state {
        case .running:
            task = started
            lock.unlock()
        case .cancelling, .finished:
            lock.unlock()
            started.cancel()
        case .ready:
            lock.unlock()
        }
    }

    public func parentDidClose() {
        lock.lock()
        switch state {
        case .ready:
            state = .finished
            lock.unlock()
            context.cancel()
            onShutdown()
        case .running:
            state = .cancelling
            let activeTask = task
            lock.unlock()
            context.cancel()
            activeTask?.cancel()
        case .cancelling, .finished:
            lock.unlock()
        }
    }

    private func workDidFinish(_ reply: WireReply) {
        lock.lock()
        switch state {
        case .running:
            state = .finished
            task = nil
            lock.unlock()
            onReply(reply)
            onShutdown()
        case .cancelling:
            state = .finished
            task = nil
            lock.unlock()
            onShutdown()
        case .ready, .finished:
            lock.unlock()
        }
    }
}

public final class ParentEOFObserver {
    private let fileDescriptor: Int32
    private let onEOF: () -> Void
    private let lock = NSLock()
    private var source: DispatchSourceRead?

    public init(fileHandle: FileHandle, onEOF: @escaping () -> Void) {
        fileDescriptor = fileHandle.fileDescriptor
        self.onEOF = onEOF
    }

    public func start() {
        lock.lock()
        guard source == nil else {
            lock.unlock()
            return
        }
        let newSource = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: .global())
        newSource.setEventHandler { [weak self] in
            self?.consumeReadableInput()
        }
        source = newSource
        newSource.resume()
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let activeSource = source
        source = nil
        lock.unlock()
        activeSource?.cancel()
    }

    private func consumeReadableInput() {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }
            if count < 0 && errno == EINTR { continue }
            if count == 0 { observedEOF() }
            return
        }
    }

    private func observedEOF() {
        lock.lock()
        guard let activeSource = source else {
            lock.unlock()
            return
        }
        source = nil
        lock.unlock()
        activeSource.cancel()
        onEOF()
    }

    deinit {
        stop()
    }
}
