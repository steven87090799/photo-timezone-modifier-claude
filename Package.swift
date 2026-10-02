// swift-tools-version: 6.4
import PackageDescription

// Shipping and validation baseline: Apple Silicon running macOS 27 or later.
let package = Package(
    name: "PhotoTimezone",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "TimezoneCore", targets: ["TimezoneCore"]),
        .executable(name: "PhotoTimezoneApp", targets: ["PhotoTimezoneApp"])
    ],
    targets: [
        .target(name: "TimezoneCore"),
        .executableTarget(name: "PhotoTimezoneApp", dependencies: ["TimezoneCore"]),
        .testTarget(name: "TimezoneCoreTests", dependencies: ["TimezoneCore"])
    ]
)
