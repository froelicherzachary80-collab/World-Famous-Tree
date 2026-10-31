// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WorldTreeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WorldTreeCore", targets: ["WorldTreeCore"])],
    targets: [
        .target(name: "WorldTreeCore"),
        .testTarget(name: "WorldTreeCoreTests", dependencies: ["WorldTreeCore"])
    ]
)
