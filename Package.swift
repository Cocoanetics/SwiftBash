// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwiftBash",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "BashSyntax", targets: ["BashSyntax"]),
        .library(name: "BashInterpreter", targets: ["BashInterpreter"]),
        .library(name: "BashCommandKit", targets: ["BashCommandKit"]),
        .executable(name: "swift-bash", targets: ["swift-bash"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser",
                 from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "BashSyntax",
            path: "Sources/BashSyntax"
        ),
        .target(
            name: "BashInterpreter",
            dependencies: ["BashSyntax"],
            path: "Sources/BashInterpreter"
        ),
        .target(
            name: "BashCommandKit",
            dependencies: [
                "BashInterpreter",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/BashCommandKit"
        ),
        .executableTarget(
            name: "swift-bash",
            dependencies: [
                "BashSyntax",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/swift-bash"
        ),
        .testTarget(
            name: "BashSyntaxTests",
            dependencies: ["BashSyntax"],
            path: "Tests/BashSyntaxTests"
        ),
        .testTarget(
            name: "BashInterpreterTests",
            dependencies: ["BashInterpreter"],
            path: "Tests/BashInterpreterTests"
        ),
        .testTarget(
            name: "BashCommandKitTests",
            dependencies: ["BashCommandKit"],
            path: "Tests/BashCommandKitTests"
        ),
    ]
)
