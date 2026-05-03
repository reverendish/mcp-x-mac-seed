// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MCPxMacSeed",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MCPxMacSeed",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "GRDB", package: "grdb.swift"),
            ]
        ),
        .testTarget(
            name: "MCPxMacSeedTests",
            dependencies: ["MCPxMacSeed"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
