// swift-tools-version: 6.4
import PackageDescription
import Foundation

let nativeJpegliLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/vendor-jpegli/lib").path
let nativeJxlPrefix = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/vendor-jxl").path
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
        .target(name: "JXLBridge", publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-I", "\(nativeJxlPrefix)/include"])],
            linkerSettings: [.unsafeFlags([
                "-L", "\(nativeJxlPrefix)/lib", "-ljxl_threads", "-ljxl", "-ljxl_cms", "\(nativeJxlPrefix)/lib/liblcms2.a",
                "-Xlinker", "-rpath", "-Xlinker", "\(nativeJxlPrefix)/lib"
            ]), .linkedLibrary("c++")]),
        .target(name: "WebPBridge", publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-I", "\(nativeJxlPrefix)/include"])],
            linkerSettings: [.unsafeFlags(["\(nativeJxlPrefix)/lib/libwebp.a", "\(nativeJxlPrefix)/lib/libsharpyuv.a"])]),
        .executableTarget(name: "PhotoTimezoneApp", dependencies: ["TimezoneCore", "JpegliBridge", "JXLBridge", "WebPBridge"]),
        .testTarget(name: "TimezoneCoreTests", dependencies: ["TimezoneCore"]),
        .testTarget(name: "CompressionAppTests", dependencies: ["PhotoTimezoneApp", "TimezoneCore"])
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
