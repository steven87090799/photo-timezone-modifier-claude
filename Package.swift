// swift-tools-version: 6.4
import PackageDescription
import Foundation

let nativeJpegliLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/vendor-jpegli/lib").path

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
        .target(name: "JpegliBridge", linkerSettings: [
            .unsafeFlags(["-L", nativeJpegliLib, "-lPhotoJpegli", "-ljpegli-static", "-lhwy"]),
            .linkedLibrary("c++")
        ]),
        .executableTarget(name: "PhotoTimezoneApp", dependencies: ["TimezoneCore", "JpegliBridge"]),
        .testTarget(name: "TimezoneCoreTests", dependencies: ["TimezoneCore"]),
        .testTarget(name: "CompressionAppTests", dependencies: ["PhotoTimezoneApp", "TimezoneCore"])
    ],
    swiftLanguageModes: [.v5]
)
