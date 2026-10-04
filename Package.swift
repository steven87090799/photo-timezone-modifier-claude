// swift-tools-version: 6.4
import PackageDescription
import Foundation

let nativeJpegliLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/vendor-jpegli/lib").path
let nativeJxlPrefix = "/opt/homebrew/opt/jpeg-xl"
let nativeHighwayPrefix = "/opt/homebrew/opt/highway"
let nativeBrotliPrefix = "/opt/homebrew/opt/brotli"
let nativeLCMSPrefix = "/opt/homebrew/opt/little-cms2"

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
        .target(name: "JXLBridge", path: "Sources/JXLBridge", publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-I", "\(nativeJxlPrefix)/include",
                                       "-I", "\(nativeLCMSPrefix)/include"])],
            linkerSettings: [.unsafeFlags([
                "-L", "\(nativeJxlPrefix)/lib", "-L", "\(nativeHighwayPrefix)/lib",
                "-L", "\(nativeBrotliPrefix)/lib", "-L", "\(nativeLCMSPrefix)/lib",
                "-ljxl_threads", "-ljxl", "-lhwy", "-lbrotlienc", "-lbrotlidec",
                "-lbrotlicommon", "-ljxl_cms", "-llcms2"
            ]), .linkedLibrary("c++")]),
        .executableTarget(name: "PhotoTimezoneApp", dependencies: ["TimezoneCore", "JpegliBridge", "JXLBridge"]),
        .testTarget(name: "TimezoneCoreTests", dependencies: ["TimezoneCore"]),
        .testTarget(name: "CompressionAppTests", dependencies: ["PhotoTimezoneApp", "TimezoneCore"])
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
