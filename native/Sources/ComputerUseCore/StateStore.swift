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

public final class StateStore {
    private let rootURL: URL
    private let currentDate: () -> Date
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(rootURL: URL = DesktopLock.defaultRootURL, now: @escaping () -> Date = Date.init) {
        self.rootURL = rootURL
        currentDate = now
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    public func writeSnapshot(_ record: SnapshotRecord) throws {
        guard let id = canonicalUUID(record.id), record.id == id,
              record.version == stateRecordVersion, record.kind == "snapshot",
              validLifetime(record) else { throw staleSnapshot() }
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
            guard record.version == stateRecordVersion,
                  record.kind == "snapshot",
                  record.id == id,
                  !record.invalidated,
                  validLifetime(record),
                  let expiration = parseTimestamp(record.expiresAt),
                  currentDate() < expiration else { throw staleSnapshot() }
            return record
        }
    }

    public func sweep() throws {
        try withSnapshotDirectory(create: true) { descriptor in
            let names = try directoryNames(descriptor)
            for name in names {
                if temporaryRecordName(name) {
                    _ = unlinkat(descriptor, name, 0)
                    continue
                }
                guard let id = recordID(from: name) else { continue }
                guard let record = try? decodeRecord(named: name, directoryDescriptor: descriptor) else { continue }
                let expired = parseTimestamp(record.expiresAt).map { currentDate() >= $0 } ?? false
                if record.id == id && (record.invalidated || expired) {
                    _ = unlinkat(descriptor, name, 0)
                }
            }
            guard fsync(descriptor) == 0 else { throw stateFailure("Unable to synchronize snapshot state") }
        }
    }

    public func invalidateRecords(for identity: TargetIdentity) throws {
        try withSnapshotDirectory(create: true) { descriptor in
            let names = try directoryNames(descriptor)
            for name in names {
                guard recordID(from: name) != nil,
                      let record = try? decodeRecord(named: name, directoryDescriptor: descriptor),
                      record.version == stateRecordVersion,
                      record.kind == "snapshot",
                      sameApplication(record.target.identity, identity),
                      !record.invalidated else { continue }
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
        let descriptor = openat(directoryDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw staleSnapshot() }
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
                let result = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result < 0 && errno == EINTR { continue }
                if result <= 0 { return -1 }
                offset += result
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
                let result = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result < 0 && errno == EINTR { continue }
                if result <= 0 { return false }
                offset += result
            }
            return true
        }
        guard wroteAll, fsync(descriptor) == 0 else { throw stateFailure("Unable to write snapshot state") }
        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, name) == 0 else {
            throw stateFailure("Unable to publish snapshot state")
        }
        shouldRemoveTemporary = false
        guard fsync(directoryDescriptor) == 0 else { throw stateFailure("Unable to synchronize snapshot state") }
    }
}

private func directoryNames(_ descriptor: Int32) throws -> [String] {
    let duplicate = dup(descriptor)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
        if duplicate >= 0 { close(duplicate) }
        throw stateFailure("Unable to enumerate snapshot state")
    }
    defer { closedir(directory) }
    var names: [String] = []
    while let entry = readdir(directory) {
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
private func parseTimestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}
private func validLifetime(_ record: SnapshotRecord) -> Bool {
    guard let creation = parseTimestamp(record.createdAt), let expiration = parseTimestamp(record.expiresAt) else { return false }
    return abs(expiration.timeIntervalSince(creation) - snapshotLifetime) < 0.001
}
private func staleSnapshot() -> NativeFailure {
    NativeFailure("STALE_SNAPSHOT", "Snapshot state is missing, invalid, expired, or invalidated")
}
