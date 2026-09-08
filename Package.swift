// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TidyNest",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TidyNestCore", targets: ["TidyNestCore"]),
        .executable(name: "TidyNest", targets: ["TidyNest"]),
        .executable(name: "TidyNestBridge", targets: ["TidyNestBridge"])
    ],
    targets: [
        .target(name: "TidyNestProtocol"),
        .target(name: "TidyNestCore", dependencies: ["TidyNestProtocol"]),
        .target(name: "TidyNestEngine", dependencies: ["TidyNestCore", "TidyNestProtocol"], resources: [.copy("Resources/MoleUpstream")]),
        .executableTarget(name: "TidyNestBridge", dependencies: ["TidyNestEngine", "TidyNestProtocol"]),
        .executableTarget(name: "TidyNest", dependencies: ["TidyNestCore", "TidyNestProtocol"]),
        .testTarget(name: "TidyNestCoreTests", dependencies: ["TidyNestCore", "TidyNestProtocol"]),
        .testTarget(name: "TidyNestEngineTests", dependencies: ["TidyNestEngine", "TidyNestProtocol", "TidyNestCore"]),
        .testTarget(name: "TidyNestUITests", dependencies: ["TidyNest", "TidyNestCore", "TidyNestProtocol"])
    ]
)
