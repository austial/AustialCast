// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AustialCastMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AustialCastProtocol", targets: ["AustialCastProtocol"]),
        .library(name: "AustialCastCore", targets: ["AustialCastCore"]),
        .executable(name: "austialcast", targets: ["austialcast"]),
        .executable(name: "AustialCastApp", targets: ["AustialCastApp"]),
    ],
    targets: [
        .target(name: "AustialCastProtocol"),
        .target(name: "AustialCastCore", dependencies: ["AustialCastProtocol"]),
        .executableTarget(name: "austialcast", dependencies: ["AustialCastCore"]),
        .executableTarget(name: "AustialCastApp", dependencies: ["AustialCastCore"]),
        .testTarget(name: "AustialCastProtocolTests", dependencies: ["AustialCastProtocol"]),
        .testTarget(name: "AustialCastCoreTests", dependencies: ["AustialCastCore", "AustialCastProtocol"]),
    ],
    swiftLanguageModes: [.v5]
)
