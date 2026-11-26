// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "Core", targets: ["Core"])],
    targets: [
        .target(name: "Core", resources: [.copy("Resources/yt.solver.lib.min.js"), .copy("Resources/yt.solver.core.min.js")]),
        .testTarget(name: "CoreTests", dependencies: ["Core"], resources: [.copy("Fixtures")]),
    ]
)
