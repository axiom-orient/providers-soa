// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "soaKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "soaKit", targets: ["soaKit"]),
        .executable(name: "soa", targets: ["soaCLI"]),
    ],
    targets: [
        .target(name: "soaKit"),
        .target(name: "soaCLIKit", dependencies: ["soaKit"]),
        .executableTarget(name: "soaCLI", dependencies: ["soaCLIKit"]),
        .testTarget(name: "soaKitTests", dependencies: ["soaKit"]),
        .testTarget(name: "soaCLIKitTests", dependencies: ["soaCLIKit"]),
    ]
)
