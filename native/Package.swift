// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ComputerUse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ComputerUseCore", targets: ["ComputerUseCore"]),
        .executable(name: "computer-use-host", targets: ["ComputerUseHost"]),
    ],
    targets: [
        .target(name: "ComputerUseCore", linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices")]),
        .executableTarget(name: "ComputerUseHost", dependencies: ["ComputerUseCore"]),
        .testTarget(name: "ComputerUseCoreTests", dependencies: ["ComputerUseCore"], resources: [.process("Fixtures")]),
    ],
    swiftLanguageVersions: [.v5]
)
