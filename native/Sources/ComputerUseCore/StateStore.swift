import Darwin
import Foundation

public let stateRecordVersion = 1
public let snapshotLifetime: TimeInterval = 10 * 60

public struct SnapshotRecord: Codable, Equatable {
    public let version: Int
    public let kind: String
    public let id: String
    public let createdAt: String
    public let expiresAt: String
    public let target: ResolvedTarget
    public let treeOptions: TreeOptions
    public let evidence: AXTreeEvidence
    public let invalidated: Bool

    public init(
        id: String,
        createdAt: String,
        expiresAt: String,
        target: ResolvedTarget,
        treeOptions: TreeOptions,
        evidence: AXTreeEvidence,
        invalidated: Bool = false
    ) {
        version = stateRecordVersion
        kind = "snapshot"
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.target = target
        self.treeOptions = treeOptions
        self.evidence = evidence
        self.invalidated = invalidated
    }

    private init(copying record: SnapshotRecord, invalidated: Bool) {
        version = record.version
        kind = record.kind
        id = record.id
        createdAt = record.createdAt
        expiresAt = record.expiresAt
        target = record.target
        treeOptions = record.treeOptions
        evidence = record.evidence
        self.invalidated = invalidated
    }

    func invalidatedCopy() -> SnapshotRecord { SnapshotRecord(copying: self, invalidated: true) }
}

struct StateStoreIO {
    let directoryNames: (Int32) throws -> [String]
    let openRecord: (Int32, String) -> SystemCallResult<Int32>
    let read: (Int32, UnsafeMutableRawPointer?, Int) -> SystemCallResult<Int>
    let write: (Int32, UnsafeRawPointer?, Int) -> SystemCallResult<Int>
    let sync: (Int32) -> SystemCallResult<Int32>
    let renameRecord: (Int32, String, Int32, String) -> SystemCallResult<Int32>

    init(
        directoryNames: @escaping (Int32) throws -> [String] = liveDirectoryNames,
        openRecord: @escaping (Int32, String) -> SystemCallResult<Int32> = { directory, name in
            let value = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        },
        read: @escaping (Int32, UnsafeMutableRawPointer?, Int) -> SystemCallResult<Int> = { descriptor, buffer, count in
            let value = Darwin.read(descriptor, buffer, count)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        },
        write: @escaping (Int32, UnsafeRawPointer?, Int) -> SystemCallResult<Int> = { descriptor, buffer, count in
            let value = Darwin.write(descriptor, buffer, count)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        },
        sync: @escaping (Int32) -> SystemCallResult<Int32> = { descriptor in
            let value = fsync(descriptor)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        },
        renameRecord: @escaping (Int32, String, Int32, String) -> SystemCallResult<Int32> = {
            oldDirectory, oldName, newDirectory, newName in
            let value = renameat(oldDirectory, oldName, newDirectory, newName)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        }
    ) {
        self.directoryNames = directoryNames
        self.openRecord = openRecord
        self.read = read
        self.write = write
        self.sync = sync
        self.renameRecord = renameRecord
    }
}

public final class StateStore {
    private let rootURL: URL
    private let currentDate: () -> Date
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let io: StateStoreIO

    public init(rootURL: URL = DesktopLock.defaultRootURL, now: @escaping () -> Date = Date.init) {
        self.rootURL = rootURL
        currentDate = now
        io = StateStoreIO()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    init(rootURL: URL, now: @escaping () -> Date, io: StateStoreIO) {
        self.rootURL = rootURL
        currentDate = now
        self.io = io
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    public func writeSnapshot(_ record: SnapshotRecord) throws {
        guard validateRecord(record, expectedID: record.id) else { throw staleSnapshot() }
        let data: Data
        do { data = try encoder.encode(record) } catch { throw stateFailure("Unable to encode snapshot state") }
        try withSnapshotDirectory(create: true) { descriptor in
            try atomicWrite(data, named: recordFileName(record.id), directoryDescriptor: descriptor, replacing: false)
        }
    }

    public func readSnapshot(id: String) throws -> SnapshotRecord {
        guard let id = canonicalUUID(id) else { throw staleSnapshot() }
        return try withSnapshotDirectory(create: false) { descriptor in
            let record = try decodeRecord(named: recordFileName(id), directoryDescriptor: descriptor)
            guard validateRecord(record, expectedID: id),
                  !record.invalidated,
                  let expiration = parseSnapshotTimestamp(record.expiresAt)?.date,
                  currentDate() < expiration else { throw staleSnapshot() }
            return record
        }
    }

    public func sweep() throws {
        try withSnapshotDirectory(create: true) { descriptor in
            let names = try io.directoryNames(descriptor)
            for name in names {
                if temporaryRecordName(name) {
                    _ = unlinkat(descriptor, name, 0)
                    continue
                }
                guard let id = recordID(from: name) else { continue }
                guard let record = try? decodeRecord(named: name, directoryDescriptor: descriptor) else { continue }
                let expired = parseSnapshotTimestamp(record.expiresAt).map { currentDate() >= $0.date } ?? false
                if record.id == id && (record.invalidated || expired) {
                    _ = unlinkat(descriptor, name, 0)
                }
            }
            guard fsync(descriptor) == 0 else { throw stateFailure("Unable to synchronize snapshot state") }
        }
    }

    public func invalidateRecords(for identity: TargetIdentity) throws {
        try withSnapshotDirectory(create: true) { descriptor in
            let names = try io.directoryNames(descriptor)
            for name in names {
                guard let id = recordID(from: name) else { continue }
                let record = try decodeRecord(named: name, directoryDescriptor: descriptor)
                guard validateRecord(record, expectedID: id) else { throw staleSnapshot() }
                guard sameApplication(record.target.identity, identity), !record.invalidated else { continue }
                let data: Data
                do { data = try encoder.encode(record.invalidatedCopy()) }
                catch { throw stateFailure("Unable to encode invalidated state") }
                try atomicWrite(data, named: name, directoryDescriptor: descriptor, replacing: true)
            }
        }
    }

    private func withSnapshotDirectory<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T {
        let rootDescriptor = try PrivateStateDirectory.openRoot(rootURL)
        defer { close(rootDescriptor) }
        let snapshotDescriptor: Int32
        do {
            snapshotDescriptor = try PrivateStateDirectory.openChild("snapshots", rootDescriptor: rootDescriptor, create: create)
        } catch where !create && errno == ENOENT {
            throw staleSnapshot()
        }
        defer { close(snapshotDescriptor) }
        return try body(snapshotDescriptor)
    }

    private func decodeRecord(named name: String, directoryDescriptor: Int32) throws -> SnapshotRecord {
        let descriptor: Int32
        while true {
            let result = io.openRecord(directoryDescriptor, name)
            if result.value >= 0 {
                descriptor = result.value
                break
            }
            if result.error == EINTR { continue }
            throw staleSnapshot()
        }
        defer { close(descriptor) }
        do { try verifyPrivateFile(descriptor) } catch { throw staleSnapshot() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_size >= 0,
              info.st_size <= 16 * 1_024 * 1_024,
              info.st_mode & 0o777 == 0o600 else { throw staleSnapshot() }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let result = io.read(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if result.value < 0 && result.error == EINTR { continue }
                if result.value <= 0 { return -1 }
                offset += result.value
            }
            return offset
        }
        guard count == data.count, let record = try? decoder.decode(SnapshotRecord.self, from: data) else { throw staleSnapshot() }
        return record
    }

    private func atomicWrite(_ data: Data, named name: String, directoryDescriptor: Int32, replacing: Bool) throws {
        if !replacing {
            var info = stat()
            guard fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT else {
                throw stateFailure("Snapshot state already exists")
            }
        }
        let temporaryName = ".tmp.\(UUID().uuidString.lowercased()).json"
        let descriptor = openat(directoryDescriptor, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw stateFailure("Unable to create snapshot state") }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary { _ = unlinkat(directoryDescriptor, temporaryName, 0) }
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw stateFailure("Unable to protect snapshot state") }
        try verifyPrivateFile(descriptor)
        let wroteAll = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let result = io.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
                if result.value < 0 && result.error == EINTR { continue }
                if result.value <= 0 { return false }
                offset += result.value
            }
            return true
        }
        guard wroteAll else {
            throw stateFailure("Unable to write snapshot state")
        }
        let fileSync = io.sync(descriptor)
        guard fileSync.value == 0 else {
            throw stateFailure("Unable to write snapshot state")
        }
        let renamed = io.renameRecord(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            name
        )
        guard renamed.value == 0 else {
            throw stateFailure("Unable to publish snapshot state")
        }
        shouldRemoveTemporary = false
        let directorySync = io.sync(directoryDescriptor)
        guard directorySync.value == 0 else {
            throw stateFailure("Unable to synchronize snapshot state")
        }
    }
}

private func liveDirectoryNames(_ descriptor: Int32) throws -> [String] {
    let duplicate = dup(descriptor)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
        if duplicate >= 0 { close(duplicate) }
        throw stateFailure("Unable to enumerate snapshot state")
    }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
        errno = 0
        guard let entry = readdir(directory) else {
            if errno == EINTR { continue }
            guard errno == 0 else { throw stateFailure("Unable to enumerate snapshot state") }
            break
        }
        let name = withUnsafePointer(to: entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
        }
        if name != "." && name != ".." { names.append(name) }
    }
    return names.sorted()
}


private func sameApplication(_ lhs: TargetIdentity, _ rhs: TargetIdentity) -> Bool {
    if let leftBundle = lhs.bundleId, let rightBundle = rhs.bundleId { return leftBundle == rightBundle }
    return lhs.pid == rhs.pid && lhs.launchDate == rhs.launchDate
}


private func canonicalUUID(_ value: String) -> String? {
    guard value.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil,
          let uuid = UUID(uuidString: value) else { return nil }
    return uuid.uuidString.lowercased()
}
private func recordFileName(_ id: String) -> String { "\(id).json" }
private func recordID(from name: String) -> String? {
    guard name.hasSuffix(".json") else { return nil }
    return canonicalUUID(String(name.dropLast(5)))
}
private func temporaryRecordName(_ name: String) -> Bool {
    guard name.hasPrefix(".tmp."), name.hasSuffix(".json") else { return false }
    return canonicalUUID(String(name.dropFirst(5).dropLast(5))) != nil
}
private struct SnapshotTimestamp {
    let seconds: Int64
    let nanoseconds: Int

    var date: Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
    }
}

private func parseSnapshotTimestamp(_ value: String) -> SnapshotTimestamp? {
    guard value.hasSuffix("Z") else { return nil }
    let body = String(value.dropLast())
    let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count <= 2 else { return nil }
    let seconds = Array(parts[0].utf8)
    let digitOffsets = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
    guard seconds.count == 19,
          seconds[4] == 45,
          seconds[7] == 45,
          seconds[10] == 84,
          seconds[13] == 58,
          seconds[16] == 58,
          digitOffsets.allSatisfy({ (48...57).contains(seconds[$0]) }) else { return nil }

    let fraction: String
    if parts.count == 2 {
        fraction = String(parts[1])
        guard (1...9).contains(fraction.utf8.count),
              fraction.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    } else {
        fraction = ""
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    formatter.isLenient = false
    guard let date = formatter.date(from: String(parts[0])) else { return nil }

    let padded = fraction.padding(toLength: 9, withPad: "0", startingAt: 0)
    guard let nanoseconds = Int(padded) else { return nil }
    return SnapshotTimestamp(
        seconds: Int64(date.timeIntervalSince1970),
        nanoseconds: nanoseconds
    )
}

private func validLifetime(_ record: SnapshotRecord) -> Bool {
    guard let creation = parseSnapshotTimestamp(record.createdAt),
          let expiration = parseSnapshotTimestamp(record.expiresAt) else { return false }
    return expiration.seconds == creation.seconds + Int64(snapshotLifetime)
        && expiration.nanoseconds == creation.nanoseconds
}

private func validateRecord(_ record: SnapshotRecord, expectedID: String) -> Bool {
    guard canonicalUUID(record.id) == record.id,
          record.id == expectedID,
          record.version == stateRecordVersion,
          record.kind == "snapshot",
          validLifetime(record),
          validPositiveSafe(record.target.identity.pid),
          validPositiveSafe(record.target.identity.windowId),
          validBounds(record.target.bounds) else { return false }

    do {
        try AXEvidencePolicy.validate(record.evidence, options: record.treeOptions)
        return true
    } catch {
        return false
    }
}

private func validPositiveSafe(_ value: Int) -> Bool {
    value > 0 && value <= maximumSafeInteger
}

private func validBounds(_ bounds: WindowBounds?) -> Bool {
    guard let bounds else { return true }
    return bounds.x.isFinite && bounds.y.isFinite && bounds.width.isFinite && bounds.height.isFinite
        && bounds.width >= 0 && bounds.height >= 0
}
private func staleSnapshot() -> NativeFailure {
    NativeFailure("STALE_SNAPSHOT", "Snapshot state is missing, invalid, expired, or invalidated")
}
