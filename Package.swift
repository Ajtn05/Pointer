// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pointer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Pointer"),
        .testTarget(name: "PointerTests", dependencies: ["Pointer"], resources: [.copy("Fixtures")])
    ]
)
