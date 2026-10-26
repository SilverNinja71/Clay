// swift-tools-version: 5.10
import PackageDescription

// Clay is split into a shared library (ClayKit) that holds every feature, and
// thin app shells. The Mac app builds with this package directly; the iPad app
// is an Xcode "App" project that links ClayKit (see README.md).
let package = Package(
    name: "Clay",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ClayKit", targets: ["ClayKit"]),
        .executable(name: "Clay", targets: ["ClayMac"]),
        .executable(name: "ClaySnapshots", targets: ["ClaySnapshots"]),
    ],
    targets: [
        .target(name: "ClayKit", path: "Sources/ClayKit"),
        .executableTarget(name: "ClayMac", dependencies: ["ClayKit"], path: "Sources/ClayMac",
                          swiftSettings: [.unsafeFlags(["-parse-as-library"])]),
        .executableTarget(name: "ClaySnapshots", dependencies: ["ClayKit"], path: "Sources/ClaySnapshots"),
        .testTarget(name: "ClayKitTests", dependencies: ["ClayKit"], path: "Tests/ClayKitTests"),
    ]
)
