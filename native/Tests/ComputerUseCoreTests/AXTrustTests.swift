import ApplicationServices
import XCTest
@testable import ComputerUseCore

final class AXTrustTests: XCTestCase {
    func testMissingOptionalValuesAndUnsupportedLeafCollectionsRemainTrustworthy() throws {
        let reader = AXTreeReader<Int>(
            string: { element, attribute in
                if attribute == kAXRoleAttribute { return .value(element == 0 ? "AXWindow" : "AXButton") }
                return .unavailable
            },
            bool: { _, _ in .unavailable },
            children: { element in element == 0 ? .value([1]) : .unavailable },
            actions: { _ in .unavailable },
            bounds: { _ in .unavailable }
        )

        let result = try AXTree.readSnapshot(
            target: trustTarget(),
            options: TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full),
            root: 0,
            reader: reader
        )

        XCTAssertEqual(result.snapshot.evidence.nodes.map(\.role), ["AXWindow", "AXButton"])
        XCTAssertNil(result.snapshot.evidence.nodes[0].title)
        XCTAssertEqual(result.snapshot.evidence.nodes[1].childCount, 0)
        XCTAssertEqual(result.snapshot.evidence.nodes[1].actions, [])
        XCTAssertEqual(result.elementsByRef.keys.sorted(), [1, 2])
        XCTAssertEqual(result.elementsByRef[1], 0)
        XCTAssertEqual(result.elementsByRef[2], 1)
    }

    func testEveryPersistedReadFailureRejectsObservationInsteadOfSerializingFallbackEvidence() {
        for failingRead in axFailureCases {
            XCTAssertThrowsError(
                try AXTree.readSnapshot(
                    target: trustTarget(),
                    options: TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full),
                    root: 0,
                    reader: failingReader(failingRead)
                ),
                failingRead
            ) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
            }
        }
    }

    func testUnavailableRoleRejectsObservation() {
        let reader = AXTreeReader<Int>(
            string: { _, _ in .unavailable },
            bool: { _, _ in .unavailable },
            children: { _ in .unavailable },
            actions: { _ in .unavailable },
            bounds: { _ in .unavailable }
        )

        XCTAssertThrowsError(
            try AXTree.readSnapshot(
                target: trustTarget(),
                options: TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full),
                root: 0,
                reader: reader
            )
        ) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
    }
}

private let axFailureCases = [
    kAXRoleAttribute,
    kAXSubroleAttribute,
    kAXIdentifierAttribute,
    kAXTitleAttribute,
    kAXDescriptionAttribute,
    kAXValueAttribute,
    kAXEnabledAttribute,
    kAXFocusedAttribute,
    kAXSelectedAttribute,
    "children",
    "actions",
    "bounds"
]

private func failingReader(_ failingRead: String) -> AXTreeReader<Int> {
    AXTreeReader(
        string: { _, attribute in
            if failingRead == attribute { return .failure }
            if attribute == kAXRoleAttribute { return .value("AXWindow") }
            return .unavailable
        },
        bool: { _, attribute in failingRead == attribute ? .failure : .unavailable },
        children: { _ in failingRead == "children" ? .failure : .unavailable },
        actions: { _ in failingRead == "actions" ? .failure : .unavailable },
        bounds: { _ in failingRead == "bounds" ? .failure : .unavailable }
    )
}

private func trustTarget() -> ResolvedTarget {
    ResolvedTarget(
        identity: TargetIdentity(
            pid: 42,
            launchDate: "2026-09-08T10:00:00Z",
            bundleId: "com.example.Editor",
            windowId: 7
        ),
        title: "Document",
        bounds: WindowBounds(x: 100, y: 100, width: 600, height: 400)
    )
}
