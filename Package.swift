// swift-tools-version:6.0
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
        .library(name: "CZlib", targets: ["CZlib"]),
        .library(name: "SwiftJSCore", targets: ["SwiftJSCore"]),
        .executable(name: "swift-bash", targets: ["swift-bash"]),
        // SwiftJS is a Node-shaped JS runtime built on Apple's
        // JavaScriptCore. Source files are gated on
        // `canImport(JavaScriptCore)` so the products register
        // everywhere but compile to empty modules / a stub binary
        // on Linux / Windows / Android. See Docs/SwiftJS.md.
        .executable(name: "swift-js", targets: ["swift-js"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser",
                 from: "1.3.0"),
        // swift-crypto exposes the same API as CryptoKit and works on
        // Linux. On Apple platforms it transparently re-exports the
        // built-in CryptoKit, so importing `Crypto` is the
        // cross-platform spelling.
        .package(url: "https://github.com/apple/swift-crypto",
                 from: "3.0.0"),
    ],
    targets: [
        // Tiny systemLibrary target wrapping the host's zlib so our
        // gzip / gunzip commands work uniformly on macOS / iOS / Linux
        // without depending on Apple's Compression framework. Apple
        // SDKs already ship <zlib.h> + libz; on Linux apt-get
        // `zlib1g-dev` provides the headers.
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib"
        ),
        // Same pattern for `<sys/xattr.h>` — the extended-attribute
        // syscalls. Linux's stock Swift Glibc module doesn't surface
        // them; this systemLibrary fills the gap. Header-only, no
        // separate library to link (xattr lives in libc itself).
        .systemLibrary(
            name: "CXattr",
            path: "Sources/CXattr"
        ),
        .target(
            name: "BashSyntax",
            path: "Sources/BashSyntax"
        ),
        .target(
            name: "BashInterpreter",
            dependencies: [
                "BashSyntax",
                // CXattr is only consumed by RealFileSystem on
                // non-Apple platforms. Conditional dep so Apple
                // builds don't pull the systemLibrary in (Apple
                // already gets the xattr functions via Darwin).
                // Android's NDK ships `<sys/xattr.h>` too, so the
                // same shim works there.
                .target(name: "CXattr",
                        condition: .when(platforms: [.linux, .android])),
            ],
            path: "Sources/BashInterpreter"
        ),
        .target(
            name: "BashCommandKit",
            dependencies: [
                "BashInterpreter",
                "CZlib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/BashCommandKit",
            linkerSettings: [
                // zlib's library file is named differently per platform —
                // `libz.{dylib,so}` on Apple/Linux, `zlib.lib` on Windows.
                .linkedLibrary("z",
                               .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux])),
                .linkedLibrary("zlib",
                               .when(platforms: [.windows])),
            ]
        ),
        .executableTarget(
            name: "swift-bash",
            dependencies: [
                "BashSyntax",
                "BashInterpreter",
                "BashCommandKit",
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

        // ---- SwiftJS — JavaScript runtime + CLI ----
        // Apple-only at the source level (`#if canImport(JavaScriptCore)`).
        // Targets register on every platform; on non-Apple they
        // compile to (essentially) empty modules.
        .target(
            name: "SwiftJSCore",
            dependencies: [
                "BashInterpreter",
                "BashCommandKit",
                "CZlib",
            ],
            path: "Sources/SwiftJSCore",
            // The runtime is single-threaded — every JSValue touch
            // happens on the main queue. Swift 6 strict concurrency
            // can't prove that statically; the workarounds would
            // obscure the runtime, so we run in v5 mode.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("z",
                               .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux])),
                .linkedLibrary("zlib",
                               .when(platforms: [.windows])),
            ]
        ),
        .executableTarget(
            name: "swift-js",
            dependencies: ["SwiftJSCore"],
            path: "Sources/swift-js",
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SwiftJSCoreTests",
            dependencies: [
                "SwiftJSCore",
                "BashInterpreter",
                "BashCommandKit",
            ],
            path: "Tests/SwiftJSCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
