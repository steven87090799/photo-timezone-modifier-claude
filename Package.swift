// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoTimezone",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PhotoTimezoneApp", targets: ["PhotoTimezoneApp"]),
        .library(name: "TimezoneCore", targets: ["TimezoneCore"])
    ],
    targets: [
        .target(name: "TimezoneCore"),
        .executableTarget(name: "PhotoTimezoneApp", dependencies: ["TimezoneCore"]),
        .testTarget(name: "TimezoneCoreTests", dependencies: ["TimezoneCore"])
    ]
)
