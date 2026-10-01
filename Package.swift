// swift-tools-version: 5.9
import PackageDescription

// Linux runs the portable core and fixture tests. The shipping UI remains macOS-only.
var products: [Product] = [.library(name: "TimezoneCore", targets: ["TimezoneCore"])]
var targets: [Target] = [
    .target(name: "TimezoneCore"),
    .testTarget(name: "TimezoneCoreTests", dependencies: ["TimezoneCore"])
]
#if os(macOS)
products.append(.executable(name: "PhotoTimezoneApp", targets: ["PhotoTimezoneApp"]))
targets.append(.executableTarget(name: "PhotoTimezoneApp", dependencies: ["TimezoneCore"]))
#endif
let package = Package(name: "PhotoTimezone", platforms: [.macOS(.v13)],
                      products: products, targets: targets)
