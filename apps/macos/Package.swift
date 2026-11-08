// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacRemoteWorkspace",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacRemoteWorkspace", targets: ["MacRemoteWorkspace"]),
        .library(name: "AppCore", targets: ["AppCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.5.0"),
    ],
    targets: [
        .binaryTarget(name: "CFreeRDP", path: "vendor/FreeRDP.xcframework"),
        .target(name: "AppCore", dependencies: ["CFreeRDP"], resources: [.copy("Migrations"), .process("Resources")], linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "MacRemoteWorkspace", dependencies: ["AppCore", .product(name: "SwiftTerm", package: "SwiftTerm")], resources: [.process("Resources")]),
        .executableTarget(name: "RdpSessionHelper", dependencies: ["AppCore"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore"]),
        .testTarget(name: "WorkspaceUITests", dependencies: ["MacRemoteWorkspace"]),
    ]
)
