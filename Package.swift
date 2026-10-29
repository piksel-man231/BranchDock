// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BranchDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "BranchDock", targets: ["BranchDock"])],
    targets: [
        .executableTarget(name: "BranchDock"),
        .testTarget(name: "BranchDockTests", dependencies: ["BranchDock"])
    ]
)
