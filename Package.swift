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
    ],
    targets: [
        .target(
            name: "BashSyntax",
            path: "Sources/BashSyntax"
        ),
        .testTarget(
            name: "BashSyntaxTests",
            dependencies: ["BashSyntax"],
            path: "Tests/BashSyntaxTests"
        ),
    ]
)
