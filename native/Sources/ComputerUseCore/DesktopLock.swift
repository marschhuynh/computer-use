import Darwin
import Foundation

public final class DesktopLock {
    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nuvin-computer-use", isDirectory: true)
    }

    private let rootURL: URL
    private let monotonicNow: () -> UInt64
    private let wait: () -> Void

    public init(
        rootURL: URL = DesktopLock.defaultRootURL,
        monotonicNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        wait: @escaping () -> Void = { usleep(10_000) }
    ) {
        self.rootURL = rootURL
        self.monotonicNow = monotonicNow
        self.wait = wait
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

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw stateFailure("Unable to acquire the desktop lock") }
            guard monotonicNow() < deadline else { throw NativeFailure("BUSY", "Another desktop operation is in progress") }
            wait()
        }
        defer { _ = flock(descriptor, LOCK_UN) }
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
    static func openRoot(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw stateFailure("Invalid state directory") }
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw stateFailure("Unable to create the state directory") }

        var pathInfo = stat()
        guard lstat(url.path, &pathInfo) == 0,
              (pathInfo.st_mode & S_IFMT) == S_IFDIR,
              pathInfo.st_uid == geteuid() else { throw stateFailure("Unsafe state directory") }
        guard chmod(url.path, 0o700) == 0 else { throw stateFailure("Unable to protect the state directory") }

        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw stateFailure("Unable to open the state directory") }
        do {
            try verifyPrivateDirectory(descriptor)
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
