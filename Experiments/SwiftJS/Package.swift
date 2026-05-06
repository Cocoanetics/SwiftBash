// swift-tools-version:6.0
import PackageDescription

// SwiftJS — feasibility experiment.
//
// A Node.js-like JavaScript executor built on JavaScriptCore.
// Provides shebang execution (`#!/usr/bin/env swift-js`) and
// custom Swift-backed bridges for the platform APIs JSC omits
// (console, process, fs, fetch, crypto, Buffer, timers, …).
//
// Lives outside the main SwiftBash Package.swift on purpose so the
// main package keeps building on Linux / Windows where JavaScriptCore
// is not available. Pulls in BashInterpreter from the parent package
// via a relative path dependency so `child_process.execSync` can
// route through SwiftBash's in-process bash runner.
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
    dependencies: [
        // Path-based dep on the parent SwiftBash package — used by
        // child_process's bash backend.
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "SwiftJSCore",
            dependencies: [
                .product(name: "BashInterpreter", package: "SwiftBash"),
                .product(name: "BashCommandKit", package: "SwiftBash"),
            ],
            path: "Sources/SwiftJSCore",
            // The runtime is single-threaded — every JSValue touch
            // happens on the main queue. Swift 6 strict concurrency
            // doesn't let us prove that statically and the workarounds
            // would obscure the experiment, so we run in v5 mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "swift-js",
            dependencies: ["SwiftJSCore"],
            path: "Sources/swift-js",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SwiftJSCoreTests",
            dependencies: [
                "SwiftJSCore",
                .product(name: "BashInterpreter", package: "SwiftBash"),
                .product(name: "BashCommandKit", package: "SwiftBash"),
            ],
            path: "Tests/SwiftJSCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
