import AppKit
import ComputerUseCore
import Darwin
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
        guard let data = readRequestLine(), let request = WireRequest.decode(data: data) else {
            write(.failure(code: "PROTOCOL_ERROR", message: "Invalid request"))
            return
        }

        _ = NSApplication.shared
        guard let timeout = request.timeoutMilliseconds else {
            write(.failure(
                command: request.command,
                code: "PROTOCOL_ERROR",
                message: "Invalid command options"
            ))
            return
        }
        let context = CommandContext(timeoutMilliseconds: timeout)
        let session = HostSession(
            context: context,
            work: { context, completion in
                Task.detached {
                    await withTaskCancellationHandler(operation: {
                        let reply = await NativeService().execute(request, context: context)
                        completion(reply)
                    }, onCancel: {
                        context.cancel()
                    })
                }
            },
            onReply: write,
            onShutdown: {
                DispatchQueue.main.async {
                    CFRunLoopStop(CFRunLoopGetMain())
                }
            }
        )
        let parentObserver = ParentEOFObserver(fileHandle: .standardInput) {
            session.parentDidClose()
        }
        parentObserver.start()
        session.start()
        CFRunLoopRun()
        parentObserver.stop()
    }

    private static func readRequestLine() -> Data? {
        var reader = BoundedLineReader()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(FileHandle.standardInput.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            let chunk = Data(buffer.prefix(count))
            switch reader.consume(chunk, endOfFile: count == 0) {
            case .awaitingInput:
                continue
            case let .line(line):
                return line
            case .invalid:
                return nil
            }
        }
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
