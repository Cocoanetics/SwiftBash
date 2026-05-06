// swift-tools-version:6.0
import PackageDescription

// SwiftJS — feasibility experiment.
//
// A minimal Node.js-like JavaScript executor built on JavaScriptCore.
// The point of this package is to find out whether we can hand a user
// a `swift-js` binary that runs `*.js` files directly (including via a
// `#!/usr/bin/env swift-js` shebang) the way `node` does.
//
// Lives outside the main SwiftBash Package.swift on purpose so the
// main package keeps building on Linux / Windows where JavaScriptCore
// is not available.
let package = Package(
    name: "SwiftJS",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "SwiftJSCore", targets: ["SwiftJSCore"]),
        .executable(name: "swift-js", targets: ["swift-js"]),
    ],
    targets: [
        .target(
            name: "SwiftJSCore",
            path: "Sources/SwiftJSCore"
        ),
        .executableTarget(
            name: "swift-js",
            dependencies: ["SwiftJSCore"],
            path: "Sources/swift-js"
        ),
        .testTarget(
            name: "SwiftJSCoreTests",
            dependencies: ["SwiftJSCore"],
            path: "Tests/SwiftJSCoreTests"
        ),
    ]
)
