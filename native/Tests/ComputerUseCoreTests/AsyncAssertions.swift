import XCTest

func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(
            message().isEmpty ? "Asynchronous expression did not throw" : message(),
            file: file,
            line: line
        )
    } catch {
        errorHandler(error)
    }
}
