import XCTest
@testable import ComputerUseCore

final class TargetResolverTests: XCTestCase {
    func testDuplicateAppNamesAreNotSelected() throws {
        let resolver = TargetResolver(inventory: .fixture("duplicate-apps"))
        XCTAssertThrowsError(try resolver.resolve(.app("Editor", windowId: nil))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "AMBIGUOUS_TARGET")
        }
    }

    func testPidReuseFailsIdentityValidation() throws {
        let resolver = TargetResolver(inventory: .fixture("pid-reused"))
        XCTAssertThrowsError(try resolver.validate(.init(pid: 42, launchDate: "old", bundleId: "com.example.Editor", windowId: 7))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
    }

    func testMissingWindowRequiresExactlyOneEligibleWindow() throws {
        let zero = TargetResolver(inventory: .fixture("zero-eligible-windows"))
        XCTAssertThrowsError(try zero.resolve(.pid(42, windowId: nil))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "INELIGIBLE_TARGET")
        }
        let multiple = TargetResolver(inventory: .fixture("multiple-eligible-windows"))
        XCTAssertThrowsError(try multiple.resolve(.pid(42, windowId: nil))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "AMBIGUOUS_TARGET")
        }
    }

    func testDuplicateAXToCGCandidatesAreRejected() throws {
        let resolver = TargetResolver(inventory: .fixture("duplicate-ax-cg"))
        XCTAssertThrowsError(try resolver.resolve(.pid(42, windowId: 7))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "AMBIGUOUS_TARGET")
        }
    }

    func testMinimizedAndOffSpaceWindowsAreIneligible() throws {
        for fixture in ["minimized-window", "off-space-window"] {
            let resolver = TargetResolver(inventory: .fixture(fixture))
            XCTAssertThrowsError(try resolver.resolve(.pid(42, windowId: 7)), fixture) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "INELIGIBLE_TARGET")
            }
        }
    }
}

extension TargetInventory {
    static func fixture(_ name: String) -> TargetInventory {
        let url = Bundle.module.url(forResource: "inventories", withExtension: "json")!
        let fixtures = try! JSONDecoder().decode([String: TargetInventory].self, from: Data(contentsOf: url))
        return fixtures[name]!
    }
}
