import Foundation

public let protocolVersion = 1
public let maximumTimeoutMilliseconds = 120_000
public let maximumSafeInteger = 9_007_199_254_740_991

public enum MutationStatus: String, Codable, CaseIterable {
    case notStarted, potentiallyApplied
}

public struct NativeFailure: Error, Equatable {
    public let code: String
    public let message: String
    public let details: [String: JSONValue]?

    public init(_ code: String, _ message: String, details: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public enum WireCommand: String, CaseIterable {
    case doctor, apps, windows, snapshot, press, setValue = "set-value", type, key, scroll, screenshot, click, move, drag
}

public struct WireRequest {
    public let command: WireCommand
    public let object: [String: Any]

    public static func decode(_ object: Any) -> WireRequest? {
        guard let object = object as? [String: Any], validRequest(object),
              let commandName = object["command"] as? String, let command = WireCommand(rawValue: commandName) else { return nil }
        return WireRequest(command: command, object: object)
    }

    public static func decode(data: Data) -> WireRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return decode(object)
    }
}

public indirect enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .bool(bool): try value.encode(bool)
        case let .number(number): try value.encode(number)
        case let .string(string): try value.encode(string)
        case let .array(array): try value.encode(array)
        case let .object(object): try value.encode(object)
        }
    }
}

public struct WireError: Codable, Equatable {
    public let code: String
    public let message: String
    public let details: [String: JSONValue]?
}

public struct WireReply: Encodable {
    public let schemaVersion = protocolVersion
    public let ok: Bool
    public let command: String?
    public let data: [String: JSONValue]?
    public let error: WireError?

    private enum CodingKeys: String, CodingKey { case schemaVersion, ok, command, data, error }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(ok, forKey: .ok)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(error, forKey: .error)
    }

    public static func success(command: WireCommand, data: [String: JSONValue]) -> WireReply {
        WireReply(ok: true, command: command.rawValue, data: data, error: nil)
    }

    public static func failure(
        command: WireCommand? = nil,
        code: String,
        message: String,
        details: [String: JSONValue]? = nil
    ) -> WireReply {
        WireReply(
            ok: false,
            command: command?.rawValue,
            data: nil,
            error: WireError(code: code, message: message, details: details)
        )
    }
}

private func validRequest(_ request: [String: Any]) -> Bool {
    guard integer(request["schemaVersion"]) == protocolVersion,
          let commandName = request["command"] as? String,
          let command = WireCommand(rawValue: commandName),
          validOptions(request["options"]) else { return false }
    let base: Set<String> = ["schemaVersion", "command", "options"]
    switch command {
    case .doctor, .apps:
        return hasExactKeys(request, base)
    case .windows:
        return hasExactKeys(request, base.union(["target"])) && validTarget(request["target"])
    case .snapshot:
        return hasExactKeys(request, base.union(["target", "tree"]))
            && validTarget(request["target"]) && validTree(request["tree"])
    case .press:
        return hasExactKeys(request, base.union(["snapshotId", "ref"]))
            && validID(request["snapshotId"]) && positiveInteger(request["ref"])
    case .setValue:
        return hasExactKeys(request, base.union(["snapshotId", "ref", "text"]))
            && validID(request["snapshotId"]) && positiveInteger(request["ref"])
            && request["text"] is String
    case .type:
        return hasExactKeys(request, base.union(["target", "text", "allowClipboardReplace"]))
            && validTarget(request["target"]) && request["text"] is String
            && validBoolean(request["allowClipboardReplace"])
    case .key:
        return hasExactKeys(request, base.union(["target", "key"]))
            && validTarget(request["target"]) && !(request["key"] as? String ?? "").isEmpty
    case .scroll:
        let refKeys = base.union(["snapshotId", "ref"])
        if hasExactKeys(request, refKeys) {
            return validID(request["snapshotId"]) && positiveInteger(request["ref"])
        }
        let directionalKeys = base.union(["target", "direction", "amount"])
        return hasExactKeys(request, directionalKeys)
            && validTarget(request["target"])
            && ["up", "down", "left", "right"].contains(request["direction"] as? String ?? "")
            && positiveInteger(request["amount"])
    case .screenshot:
        return hasExactKeys(request, base.union(["target", "output", "overwrite", "annotated", "tree"]))
            && validTarget(request["target"]) && !(request["output"] as? String ?? "").isEmpty
            && validBoolean(request["overwrite"]) && validBoolean(request["annotated"])
            && validTree(request["tree"])
    case .click:
        return hasExactKeys(request, base.union(["captureId", "point", "button", "count"]))
            && validID(request["captureId"]) && validPoint(request["point"])
            && ["left", "right", "middle"].contains(request["button"] as? String ?? "")
            && [1, 2, 3].contains(integer(request["count"]) ?? 0)
    case .move:
        return hasExactKeys(request, base.union(["captureId", "point"]))
            && validID(request["captureId"]) && validPoint(request["point"])
    case .drag:
        return hasExactKeys(request, base.union(["captureId", "from", "to"]))
            && validID(request["captureId"]) && validPoint(request["from"])
            && validPoint(request["to"])
    }
}

private func validOptions(_ value: Any?) -> Bool {
    guard let options = value as? [String: Any],
          hasExactKeys(options, ["timeoutMs", "cursor"]),
          let timeout = integer(options["timeoutMs"]) else { return false }
    return (1...maximumTimeoutMilliseconds).contains(timeout)
        && ["on", "off"].contains(options["cursor"] as? String ?? "")
}

private func validTarget(_ value: Any?) -> Bool {
    guard let target = value as? [String: Any] else { return false }
    let keys = Set(target.keys)
    if keys == ["app"] || keys == ["app", "windowId"] {
        guard let app = target["app"] as? String, !app.isEmpty else { return false }
        return keys == ["app"] || positiveInteger(target["windowId"])
    }
    if keys == ["pid"] || keys == ["pid", "windowId"] {
        guard positiveInteger(target["pid"]) else { return false }
        return keys == ["pid"] || positiveInteger(target["windowId"])
    }
    return false
}

private func validTree(_ value: Any?) -> Bool {
    guard let tree = value as? [String: Any],
          hasExactKeys(tree, ["maxDepth", "maxElements", "hintMode"]) else { return false }
    return positiveInteger(tree["maxDepth"]) && positiveInteger(tree["maxElements"])
        && ["full", "leafOnly", "leafCompact"].contains(tree["hintMode"] as? String ?? "")
}

private func validPoint(_ value: Any?) -> Bool {
    guard let point = value as? [String: Any], hasExactKeys(point, ["x", "y"]),
          let x = number(point["x"]), let y = number(point["y"]) else { return false }
    return x.isFinite && y.isFinite && x >= 0 && y >= 0
}

private func validBoolean(_ value: Any?) -> Bool {
    guard let value = value as? NSNumber else { return false }
    return CFGetTypeID(value) == CFBooleanGetTypeID()
}

private func hasExactKeys(_ object: [String: Any], _ expected: Set<String>) -> Bool {
    Set(object.keys) == expected
}

private func validID(_ value: Any?) -> Bool {
    guard let value = value as? String else { return false }
    return value.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
}

private func positiveInteger(_ value: Any?) -> Bool { (integer(value) ?? 0) > 0 }
private func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let value = number.doubleValue
    guard value.isFinite, value.rounded() == value, abs(value) <= Double(maximumSafeInteger) else { return nil }
    return Int(value)
}
private func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number.doubleValue
}
