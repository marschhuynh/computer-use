import Foundation

public let protocolVersion = 1
public let maximumTimeoutMilliseconds = 120_000

public struct NativeFailure: Error, Equatable {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
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

public indirect enum JSONValue: Codable {
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

    public static func failure(command: WireCommand? = nil, code: String, message: String) -> WireReply {
        WireReply(ok: false, command: command?.rawValue, data: nil, error: WireError(code: code, message: message))
    }
}

private func validRequest(_ request: [String: Any]) -> Bool {
    guard integer(request["schemaVersion"]) == protocolVersion,
          let commandName = request["command"] as? String, let command = WireCommand(rawValue: commandName),
          validOptions(request["options"]) else { return false }
    switch command {
    case .doctor, .apps:
        return true
    case .windows:
        return validTarget(request["target"])
    case .snapshot:
        return validTarget(request["target"]) && validTree(request["tree"])
    case .press:
        return validID(request["snapshotId"]) && positiveInteger(request["ref"])
    case .setValue:
        return validID(request["snapshotId"]) && positiveInteger(request["ref"]) && request["text"] is String
    case .type:
        return validTarget(request["target"]) && request["text"] is String && request["allowClipboardReplace"] is Bool
    case .key:
        return validTarget(request["target"]) && request["key"] is String
    case .scroll:
        if validID(request["snapshotId"]) { return positiveInteger(request["ref"]) }
        return validTarget(request["target"]) && ["up", "down", "left", "right"].contains(request["direction"] as? String ?? "") && positiveInteger(request["amount"])
    case .screenshot:
        return validTarget(request["target"]) && request["output"] is String && request["overwrite"] is Bool && request["annotated"] is Bool && validTree(request["tree"])
    case .click:
        return validID(request["captureId"]) && validPoint(request["point"]) && ["left", "right", "middle"].contains(request["button"] as? String ?? "") && [1, 2, 3].contains(integer(request["count"]) ?? 0)
    case .move:
        return validID(request["captureId"]) && validPoint(request["point"])
    case .drag:
        return validID(request["captureId"]) && validPoint(request["from"]) && validPoint(request["to"])
    }
}

private func validOptions(_ value: Any?) -> Bool {
    guard let options = value as? [String: Any], let timeout = integer(options["timeoutMs"]) else { return false }
    return (1...maximumTimeoutMilliseconds).contains(timeout) && ["on", "off"].contains(options["cursor"] as? String ?? "")
}

private func validTarget(_ value: Any?) -> Bool {
    guard let target = value as? [String: Any] else { return false }
    let app = target["app"] as? String
    let pid = integer(target["pid"])
    guard (app != nil) != (pid != nil && pid! > 0) else { return false }
    return target["windowId"] == nil || positiveInteger(target["windowId"])
}

private func validTree(_ value: Any?) -> Bool {
    guard let tree = value as? [String: Any] else { return false }
    return positiveInteger(tree["maxDepth"]) && positiveInteger(tree["maxElements"]) && ["full", "leafOnly", "leafCompact"].contains(tree["hintMode"] as? String ?? "")
}

private func validPoint(_ value: Any?) -> Bool {
    guard let point = value as? [String: Any], let x = number(point["x"]), let y = number(point["y"]) else { return false }
    return x.isFinite && y.isFinite && x >= 0 && y >= 0
}

private func validID(_ value: Any?) -> Bool {
    guard let value = value as? String else { return false }
    return value.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
}

private func positiveInteger(_ value: Any?) -> Bool { (integer(value) ?? 0) > 0 }
private func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let value = number.doubleValue
    guard value.isFinite, value.rounded() == value, value <= Double(Int.max), value >= Double(Int.min) else { return nil }
    return Int(value)
}
private func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number.doubleValue
}
