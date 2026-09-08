import AppKit
import ComputerUseCore
import Foundation

@main
struct ComputerUseHost {
    static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--protocol-version"]) {
            print(protocolVersion)
            return
        }
        guard CommandLine.arguments.count == 1 else {
            write(.failure(code: "PROTOCOL_ERROR", message: "Invalid host invocation"))
            return
        }
        guard let line = readLine(), let request = WireRequest.decode(data: Data(line.utf8)) else {
            write(.failure(code: "PROTOCOL_ERROR", message: "Invalid request"))
            return
        }
        _ = NSApplication.shared
        DispatchQueue.main.async {
            write(NativeService().execute(request))
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
    }

    private static func write(_ reply: WireReply) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(reply), let line = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data("Native host failed to encode a response\n".utf8))
            return
        }
        print(line)
    }
}
