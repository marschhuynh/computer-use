import Darwin
import Foundation

struct SystemCallResult<Value> {
    let value: Value
    let error: Int32
}

public final class DesktopLock {
    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nuvin-computer-use", isDirectory: true)
    }

    private let rootURL: URL
    private let monotonicNow: () -> UInt64
    private let wait: () -> Void
    private let flockCall: (Int32, Int32) -> SystemCallResult<Int32>

    public init(
        rootURL: URL = DesktopLock.defaultRootURL,
        monotonicNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        wait: @escaping () -> Void = { usleep(10_000) }
    ) {
        self.rootURL = rootURL
        self.monotonicNow = monotonicNow
        self.wait = wait
        flockCall = { descriptor, operation in
            let value = flock(descriptor, operation)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        }
    }

    init(
        rootURL: URL,
        monotonicNow: @escaping () -> UInt64,
        wait: @escaping () -> Void,
        flock: @escaping (Int32, Int32) -> SystemCallResult<Int32>
    ) {
        self.rootURL = rootURL
        self.monotonicNow = monotonicNow
        self.wait = wait
        flockCall = flock
    }

    public func withLock<T>(timeoutMilliseconds: Int, _ body: () throws -> T) throws -> T {
        let milliseconds = max(0, timeoutMilliseconds)
        let increment = UInt64(milliseconds) * 1_000_000
        let now = monotonicNow()
        let deadline = now > UInt64.max - increment ? UInt64.max : now + increment
        return try withLock(deadline: deadline, body)
    }

    func withLock<T>(deadline: UInt64, _ body: () throws -> T) throws -> T {
        let rootDescriptor = try PrivateStateDirectory.openRoot(rootURL)
        defer { close(rootDescriptor) }
        let descriptor = try openLockFile(in: rootDescriptor)
        defer { close(descriptor) }
        try verifyPrivateFile(descriptor)
        guard fchmod(descriptor, 0o600) == 0 else { throw stateFailure("Unable to protect the desktop lock") }

        while true {
            guard monotonicNow() < deadline else { throw NativeFailure("BUSY", "Another desktop operation is in progress") }
            let result = flockCall(descriptor, LOCK_EX | LOCK_NB)
            if result.value == 0 {
                guard monotonicNow() < deadline else {
                    _ = flockCall(descriptor, LOCK_UN)
                    throw NativeFailure("BUSY", "Another desktop operation is in progress")
                }
                break
            }
            let lockError = result.error
            if lockError == EINTR { continue }
            guard lockError == EWOULDBLOCK || lockError == EAGAIN else { throw stateFailure("Unable to acquire the desktop lock") }
            guard monotonicNow() < deadline else { throw NativeFailure("BUSY", "Another desktop operation is in progress") }
            wait()
        }
        defer { _ = flockCall(descriptor, LOCK_UN) }
        return try body()
    }

    func now() -> UInt64 { monotonicNow() }
}
private func openLockFile(in rootDescriptor: Int32) throws -> Int32 {
    while true {
        let existing = openat(rootDescriptor, "desktop.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        if existing >= 0 { return existing }
        if errno == EINTR { continue }
        guard errno == ENOENT else { throw stateFailure("Unable to open the desktop lock") }

        let created = openat(rootDescriptor, "desktop.lock", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if created >= 0 { return created }
        if errno == EINTR || errno == EEXIST { continue }
        throw stateFailure("Unable to create the desktop lock")
    }
}



struct PrivateStateDirectory {
    static func openRoot(_ url: URL, afterOpen: (Int32) throws -> Void = { _ in }) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw stateFailure("Invalid state directory") }
        while mkdir(url.path, 0o700) != 0 {
            if errno == EINTR { continue }
            guard errno == EEXIST else { throw stateFailure("Unable to create the state directory") }
            break
        }

        let descriptor: Int32
        while true {
            let opened = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if opened >= 0 {
                descriptor = opened
                break
            }
            if errno == EINTR { continue }
            throw stateFailure("Unable to open the state directory")
        }
        do {
            try afterOpen(descriptor)
            try verifyPrivateDirectory(descriptor)
            guard fchmod(descriptor, 0o700) == 0 else { throw stateFailure("Unable to protect the state directory") }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func openChild(_ name: String, rootDescriptor: Int32, create: Bool) throws -> Int32 {
        if create && mkdirat(rootDescriptor, name, 0o700) != 0 && errno != EEXIST {
            throw stateFailure("Unable to create the state records directory")
        }
        let descriptor = openat(rootDescriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw stateFailure("Unable to open the state records directory") }
        do {
            try verifyPrivateDirectory(descriptor)
            guard fchmod(descriptor, 0o700) == 0 else { throw stateFailure("Unable to protect the state records directory") }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }
}

func verifyPrivateDirectory(_ descriptor: Int32) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFDIR,
          info.st_uid == geteuid() else { throw stateFailure("Unsafe state directory") }
}

func verifyPrivateFile(_ descriptor: Int32) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == geteuid(),
          info.st_nlink == 1 else { throw stateFailure("Unsafe state file") }
}

func stateFailure(_ message: String) -> NativeFailure {
    NativeFailure("NATIVE_FAILURE", message)
}
