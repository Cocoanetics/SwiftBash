// swift-tools-version:6.2
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
        // ShellKit owns the virtualised runtime context: IO sinks,
        // Environment, Sandbox URL gate, NetworkConfig, ProcessTable,
        // HostInfo, BinCatalog, the Command protocol, and the
        // `Shell.current` TaskLocal. SwiftBash subclasses
        // `ShellKit.Shell` to add bash-specific state on top.
        // Pinned to `main` until ShellKit ships a tagged release.
        .package(url: "https://github.com/Cocoanetics/ShellKit",
                 branch: "main"),
        // SwiftPorts ports the standard CLI tool surface — `gh`,
        // `glab`, `git`, `jq`, `tar`, `zip`/`unzip`, the gzip /
        // bzip2 / xz / zstd / lz4 compression families — as
        // AsyncParsableCommand types we register as Bash builtins.
        // Each command reads/writes through `Shell.current`, so
        // they participate fully in pipes / redirection / capture.
        // Pinned to `main` until SwiftPorts ships a tagged release.
        .package(url: "https://github.com/Cocoanetics/SwiftPorts",
                 branch: "main"),
    ],
    targets: [
        // The CZlib systemLibrary that used to live here was deleted
        // when the in-process gzip / gunzip / tar CLIs moved to
        // [SwiftPorts](https://github.com/Cocoanetics/SwiftPorts).
        // SwiftJSCore's `node:zlib` JS module backing now consumes
        // `GzipKit.Zlib` (with sync variants for the JS-runtime
        // hook), so SwiftBash no longer needs its own zlib bindings.
        //
        // `<sys/xattr.h>` — the extended-attribute syscalls. Linux's
        // stock Swift Glibc module doesn't surface them; this
        // systemLibrary fills the gap. Header-only, no separate
        // library to link (xattr lives in libc itself).
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
                .product(name: "ShellKit", package: "ShellKit"),
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
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto"),
                // SwiftPorts ships these AsyncParsableCommand types
                // as library products — we register them as builtins
                // via `Shell+SwiftPortsCommands.registerSwiftPortsCommands()`.
                // Each one reads/writes through `Shell.current`, so
                // pipes / redirection / `$(...)` capture all just work.
                .product(name: "JqCommand", package: "SwiftPorts"),
                .product(name: "GhCommand", package: "SwiftPorts"),
                .product(name: "GlabCommand", package: "SwiftPorts"),
                .product(name: "GitCommand", package: "SwiftPorts"),
                .product(name: "TarCommand", package: "SwiftPorts"),
                .product(name: "ZipCommand", package: "SwiftPorts"),
                .product(name: "UnzipCommand", package: "SwiftPorts"),
                .product(name: "GzipCommand", package: "SwiftPorts"),
                .product(name: "Bzip2Command", package: "SwiftPorts"),
                .product(name: "XzCommand", package: "SwiftPorts"),
                .product(name: "ZstdCommand", package: "SwiftPorts"),
                .product(name: "Lz4Command", package: "SwiftPorts"),
            ],
            path: "Sources/BashCommandKit"
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
                .product(name: "GzipKit", package: "SwiftPorts"),
            ],
            path: "Sources/SwiftJSCore",
            // The runtime is single-threaded — every JSValue touch
            // happens on the main queue. Swift 6 strict concurrency
            // can't prove that statically; the workarounds would
            // obscure the runtime, so we run in v5 mode.
            //
            // No `linkedLibrary("z", ...)` here — GzipKit (which
            // owns the `node:zlib` backing now) carries its own zlib
            // linkage transitively.
            swiftSettings: [.swiftLanguageMode(.v5)]
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
