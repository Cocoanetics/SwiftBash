// swift-tools-version:6.2
import PackageDescription
import Foundation

// Absolute path to the package root, used to feed `-L` to the
// linker on non-Apple platforms (relative paths don't work — the
// linker's CWD is the SwiftPM build dir, not the package root).
let packageRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
    .deletingLastPathComponent().path

// Bun's prebuilt JavaScriptCore static archive lives here after
// `scripts/fetch-bun-webkit.sh` runs. The script symlinks `current`
// at the per-triple stage dir; CJavaScriptCore's header / library
// search paths point at this stable name. The linker settings below
// reference an absolute path because SwiftPM's `unsafeFlags` are
// passed through to the linker verbatim.
let bunWebKitDir = "\(packageRoot)/Vendor/bun-webkit/current"
let bunWebKitLib = "\(bunWebKitDir)/lib"
let bunWebKitFetched = FileManager.default.fileExists(
    atPath: "\(bunWebKitDir)/include/JavaScriptCore/JavaScript.h")

// `swift-jsc-smoke` proves end-to-end JSC linkage. Apple gets the
// system framework (autolink), so it always builds. On non-Apple
// hosts we only register it when the static archive has been
// staged; otherwise a plain `swift build` without the fetcher
// having run would fail to link. CI on Linux/Windows/Android runs
// the fetcher unconditionally, so the smoke target is built there.
#if canImport(Darwin)
let registerJSCSmoke = true
#else
let registerJSCSmoke = bunWebKitFetched
#endif

// Platforms where the SwiftPorts dep graph links cleanly. Android
// is excluded: SwiftPorts pulls in libgit2, BoringSSL,
// swift-archive, and several pkg-config-driven systemLibrary
// shims that emit unconditional `-lz` / `-ldl` and host
// pkg-config paths on Android, which leaks `/lib/x86_64-linux-gnu/`
// onto ld.lld and breaks Bionic libc symbol resolution. SwiftBash
// on Android ships without the SwiftPorts CLI surface (bash
// interpreter + native command catalog still work).
let swiftPortsPlatforms: [Platform] = [
    .macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux, .windows,
]

var products: [Product] = [
    .library(name: "BashSyntax", targets: ["BashSyntax"]),
    .library(name: "BashInterpreter", targets: ["BashInterpreter"]),
    .library(name: "BashCommandKit", targets: ["BashCommandKit"]),
    .library(name: "SwiftJSCore", targets: ["SwiftJSCore"]),
    .library(name: "BashSwiftScript", targets: ["BashSwiftScript"]),
    .executable(name: "swift-bash", targets: ["swift-bash"]),
    // SwiftJS is a Node-shaped JS runtime built on Apple's
    // JavaScriptCore. Source files are gated on
    // `canImport(JavaScriptCore)` so the products register
    // everywhere but compile to empty modules / a stub binary
    // on Linux / Windows / Android. See Docs/SwiftJS.md.
    .executable(name: "swift-js", targets: ["swift-js"]),
]
if registerJSCSmoke {
    // `swift-jsc-smoke` proves end-to-end JSC linkage on every
    // platform — Apple via the system framework, the others via
    // Bun's prebuilt static archive (oven-sh/WebKit autobuild)
    // staged by `scripts/fetch-bun-webkit.sh`. Registered only
    // when JSC is reachable on the host so a fetcher-less
    // `swift build` on non-Apple still succeeds for the rest of
    // the package. See Docs/SwiftJS.md § Cross-platform.
    products.append(
        .executable(name: "swift-jsc-smoke", targets: ["swift-jsc-smoke"]))
}

let package = Package(
    name: "SwiftBash",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: products,
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
        // SwiftScript — Swift tree-walking interpreter that reads
        // its IO / FS / network / identity / exit through
        // `ShellKit.Shell.current`. The `BashSwiftScript` target
        // registers it as a `swift-script` / `swift` shebang
        // interpreter so `./hello.swift` from a bash script (or
        // `swift-bash exec hello.swift`) routes through it.
        // Pinned to `main` until SwiftScript ships a tagged release.
        .package(url: "https://github.com/Cocoanetics/SwiftScript",
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
                //
                // Gated off on Android: SwiftPorts' transitive C
                // graph (libgit2, BoringSSL, swift-archive, the
                // systemLibrary pkg-config shims) emits
                // unconditional `-lz` / `-ldl` plus host-pkg-config
                // search paths on Android, which pulls
                // `/lib/x86_64-linux-gnu/` onto ld.lld and breaks
                // Bionic libc symbol resolution at link time. Until
                // that's resolved upstream, SwiftBash on Android
                // ships without the SwiftPorts CLIs (the bash
                // interpreter + native command surface still work).
                .product(name: "JqCommand", package: "SwiftPorts",
                         condition: .when(platforms: swiftPortsPlatforms)),
                .product(name: "GhCommand", package: "SwiftPorts",
                         condition: .when(platforms: swiftPortsPlatforms)),
                .product(name: "GlabCommand", package: "SwiftPorts",
                         condition: .when(platforms: swiftPortsPlatforms)),
                .product(name: "GitCommand", package: "SwiftPorts",
                         condition: .when(platforms: swiftPortsPlatforms)),
                .product(name: "TarCommand", package: "SwiftPorts",
                         condition: .when(platforms: swiftPortsPlatforms)),
                .product(name: "ZipCommand", package: "SwiftPorts",
                         condition: .when(platforms: swiftPortsPlatforms)),
                .product(name: "UnzipCommand", package: "SwiftPorts",
                         condition: .when(platforms: swiftPortsPlatforms)),
                .product(name: "GzipCommand", package: "SwiftPorts",
                         condition: .when(platforms: swiftPortsPlatforms)),
                .product(name: "Bzip2Command", package: "SwiftPorts",
                         condition: .when(platforms: swiftPortsPlatforms)),
                .product(name: "XzCommand", package: "SwiftPorts",
                         condition: .when(platforms: swiftPortsPlatforms)),
                .product(name: "ZstdCommand", package: "SwiftPorts",
                         condition: .when(platforms: swiftPortsPlatforms)),
                .product(name: "Lz4Command", package: "SwiftPorts",
                         condition: .when(platforms: swiftPortsPlatforms)),
            ],
            path: "Sources/BashCommandKit"
        ),
        .executableTarget(
            name: "swift-bash",
            dependencies: [
                "BashSyntax",
                "BashInterpreter",
                "BashCommandKit",
                "BashSwiftScript",
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
        // Universal: SwiftJSCore talks to the JSC C API exclusively
        // (via `CJavaScriptCore`), so it compiles unchanged on every
        // platform. Engine binary differs per platform — Apple
        // resolves `<JavaScriptCore/JavaScript.h>` through the system
        // framework, non-Apple through Bun's prebuilt static archive
        // staged by `scripts/fetch-bun-webkit.sh`. See Docs/SwiftJS.md.
        .target(
            name: "SwiftJSCore",
            dependencies: [
                "BashInterpreter",
                "BashCommandKit",
                // CJavaScriptCore is the only path through which any
                // JSC symbol enters SwiftJSCore. On Apple it auto-
                // links the system framework via the umbrella
                // header; on Linux/Android it pulls Bun's static
                // archive through the linker settings on
                // CJavaScriptCore itself. Gated off Windows pending
                // CRT alignment (see Docs/SwiftJS.md § Cross-platform).
                .target(name: "CJavaScriptCore",
                        condition: .when(platforms: [
                            .macOS, .iOS, .tvOS, .watchOS, .visionOS,
                            .linux, .android,
                        ])),
                // swift-crypto backs `node:crypto`. On Apple
                // platforms `Crypto` is a thin re-export of the
                // built-in `CryptoKit`; on Linux/Android it ships
                // its own implementation. Same call sites either
                // way, so SwiftJSCore depends on `Crypto`
                // unconditionally.
                .product(name: "Crypto", package: "swift-crypto"),
                // GzipKit backs the `node:zlib` JS module. Gated
                // off Android because GzipKit's `CZlib` systemLibrary
                // uses pkgConfig and bleeds host glibc paths onto
                // Android's link line.
                .product(name: "GzipKit", package: "SwiftPorts",
                         condition: .when(platforms: swiftPortsPlatforms)),
            ],
            path: "Sources/SwiftJSCore",
            // The runtime is single-threaded — every JSValue touch
            // happens on the main queue. Swift 6 strict concurrency
            // can't prove that statically; the workarounds would
            // obscure the runtime, so we run in v5 mode.
            //
            // `import CJavaScriptCore` in this target's Swift sources
            // makes Swift build a clang module from the C target's
            // umbrella header (`#include <JavaScriptCore/JavaScript.h>`).
            // That clang invocation needs the bun-webkit header path
            // and the static-linkage defines explicitly via `-Xcc`
            // — `cSettings` on the C target alone doesn't reach it.
            // Same plumbing that swift-jsc-smoke uses (PR #20).
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(
                    ["-Xcc", "-I\(bunWebKitDir)/include",
                     "-Xcc", "-DSTATICALLY_LINKED_WITH_JavaScriptCore",
                     "-Xcc", "-DSTATICALLY_LINKED_WITH_WTF"],
                    .when(platforms: [.linux, .windows, .android])),
            ]
        ),
        .executableTarget(
            name: "swift-js",
            dependencies: ["SwiftJSCore"],
            path: "Sources/swift-js",
            exclude: ["Resources"],
            // `import SwiftJSCore` here makes Swift build (or
            // re-build) the CJavaScriptCore clang module on the
            // consumer side. SwiftPM doesn't propagate
            // `swiftSettings.unsafeFlags` across target deps, so
            // the same `-Xcc -I<Vendor>` + `-DSTATICALLY_LINKED_*`
            // flags from SwiftJSCore have to be repeated here or
            // the umbrella header's
            // `#include <JavaScriptCore/JavaScript.h>` fails.
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(
                    ["-Xcc", "-I\(bunWebKitDir)/include",
                     "-Xcc", "-DSTATICALLY_LINKED_WITH_JavaScriptCore",
                     "-Xcc", "-DSTATICALLY_LINKED_WITH_WTF"],
                    .when(platforms: [.linux, .windows, .android])),
            ]
        ),
        .testTarget(
            name: "SwiftJSCoreTests",
            dependencies: [
                "SwiftJSCore",
                "BashInterpreter",
                "BashCommandKit",
            ],
            path: "Tests/SwiftJSCoreTests",
            // `@testable import SwiftJSCore` here can re-trigger the
            // clang module build for `CJavaScriptCore`; mirror the
            // SwiftJSCore target's `-Xcc` flags so the test binary
            // links cleanly on Linux + Android.
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(
                    ["-Xcc", "-I\(bunWebKitDir)/include",
                     "-Xcc", "-DSTATICALLY_LINKED_WITH_JavaScriptCore",
                     "-Xcc", "-DSTATICALLY_LINKED_WITH_WTF"],
                    .when(platforms: [.linux, .windows, .android])),
            ]
        ),

        // ---- BashSwiftScript — Swift script-shebang interpreter ----
        // Registers SwiftScript's `Interpreter` as the handler for
        // `#!/usr/bin/env swift-script` (and `swift`) shebangs on a
        // SwiftBash `Shell`. The bridge is thin because SwiftScript
        // already routes its IO / FS / network / identity / exit
        // through `ShellKit.Shell.current` — the same surface
        // SwiftBash binds for its bash interpreter. Wire-up:
        //
        //   shell.registerStandardCommands()    // BashCommandKit
        //   shell.registerSwiftScript()         // BashSwiftScript
        //   try await shell.run("./script.swift")
        .target(
            name: "BashSwiftScript",
            dependencies: [
                "BashInterpreter",
                .product(name: "SwiftScriptInterpreter", package: "SwiftScript"),
            ],
            path: "Sources/BashSwiftScript"
        ),
        .testTarget(
            name: "BashSwiftScriptTests",
            dependencies: [
                "BashSwiftScript",
                "BashInterpreter",
            ],
            path: "Tests/BashSwiftScriptTests"
        ),

        // ---- CJavaScriptCore — JSC C-API umbrella module ----
        // Re-exports the stable JavaScriptCore C API (`JSContextRef`,
        // `JSValueRef`, etc.) so Swift code can `import CJavaScriptCore`
        // and call into the engine without depending on Apple's
        // Objective-C wrapper layer (`JSContext` / `JSValue`).
        //
        //   Apple    →  resolves to `JavaScriptCore.framework`
        //               (system include path + autolink).
        //   non-Apple → resolves to Bun's prebuilt archive staged
        //               under Vendor/bun-webkit/current/{include,lib}
        //               by `scripts/fetch-bun-webkit.sh`.
        //
        // SwiftJSCore stays Apple-only at the source level for now
        // (it uses `JSContext` / `JSValue`, which don't ship in the
        // Bun tarball). Wiring SwiftJSCore through CJavaScriptCore
        // on non-Apple is a follow-up that needs a Swift-side
        // `JSContext` / `JSValue` wrapper over the C API.
        .target(
            name: "CJavaScriptCore",
            path: "Sources/CJavaScriptCore",
            publicHeadersPath: "include",
            cSettings: [
                // Absolute `-I` to the staged Bun-WebKit headers.
                // Tried `.headerSearchPath("../../Vendor/...")`
                // first — the path is documented as relative to
                // the target source dir, but under SwiftPM 6.2 it
                // didn't reach the clang module build triggered
                // by the Swift importer, and CI consistently
                // failed with `'JavaScriptCore/JavaScript.h' file
                // not found`. Absolute path via `unsafeFlags`
                // sidesteps the relative-path resolution entirely.
                .unsafeFlags(
                    ["-I\(bunWebKitDir)/include"],
                    .when(platforms: [.linux, .windows, .android])),
                // JSC's C API headers decorate every export with
                // `__declspec(dllimport)` on Windows by default,
                // which forces consumers to link a `.dll`. Bun's
                // tarball ships static `.lib`s instead, so we
                // need to disable that decoration. WebKit's
                // convention is the `STATICALLY_LINKED_WITH_*`
                // macros — defining them on JSC and WTF flips
                // the export macro to a no-op for static linkage.
                // Harmless on Linux/Android (those headers gate
                // dllimport on `_WIN32`), but defining it
                // unconditionally on every non-Apple platform
                // keeps the configuration uniform.
                .define("STATICALLY_LINKED_WITH_JavaScriptCore",
                        .when(platforms: [.linux, .windows, .android])),
                .define("STATICALLY_LINKED_WITH_WTF",
                        .when(platforms: [.linux, .windows, .android])),
            ],
            linkerSettings: [
                // Linux / Android — link Bun's static archive.
                // `-L` needs absolute path because the linker's
                // CWD is the SwiftPM build dir, not the repo root.
                .unsafeFlags(["-L\(bunWebKitLib)"],
                             .when(platforms: [.linux, .android])),
                .linkedLibrary("JavaScriptCore",
                               .when(platforms: [.linux, .android])),
                .linkedLibrary("WTF",
                               .when(platforms: [.linux, .android])),
                .linkedLibrary("bmalloc",
                               .when(platforms: [.linux, .android])),
                .linkedLibrary("icui18n",
                               .when(platforms: [.linux, .android])),
                .linkedLibrary("icuuc",
                               .when(platforms: [.linux, .android])),
                .linkedLibrary("icudata",
                               .when(platforms: [.linux, .android])),
                // pthread / dl / m are separate `.so`s on glibc but
                // collapsed into Bionic's libc on Android (no
                // `libpthread.so` / `libdl.so` / `libm.so` ship in
                // the NDK), so the Android NDK linker hard-errors
                // with "unable to find library -lpthread" if we
                // emit `-lpthread`. Linux glibc only.
                .linkedLibrary("pthread", .when(platforms: [.linux])),
                .linkedLibrary("dl", .when(platforms: [.linux])),
                .linkedLibrary("m", .when(platforms: [.linux])),
                // libc++ on Android (NDK), libstdc++ on glibc Linux.
                .linkedLibrary("stdc++", .when(platforms: [.linux])),
                .linkedLibrary("c++", .when(platforms: [.android])),
                // Bun's Android JSC archive calls into the NDK's
                // logging API (`__android_log_print` /
                // `__android_log_write`); resolve via `-llog`.
                .linkedLibrary("log", .when(platforms: [.android])),

                // Windows MSVC. `linkedLibrary("Foo")` becomes
                // `Foo.lib`; Bun's Windows tarball ships static ICU
                // as `sicuin.lib` / `sicuuc.lib` / `sicudt.lib`.
                .unsafeFlags(["-L\(bunWebKitLib)"],
                             .when(platforms: [.windows])),
                .linkedLibrary("JavaScriptCore",
                               .when(platforms: [.windows])),
                .linkedLibrary("WTF",
                               .when(platforms: [.windows])),
                .linkedLibrary("bmalloc",
                               .when(platforms: [.windows])),
                .linkedLibrary("sicuin",
                               .when(platforms: [.windows])),
                .linkedLibrary("sicuuc",
                               .when(platforms: [.windows])),
                .linkedLibrary("sicudt",
                               .when(platforms: [.windows])),
                // Apple platforms autolink the framework via the
                // umbrella header's `#include <JavaScriptCore/...>`
                // — no explicit linkerSetting needed.
            ]
        ),
    ] + (registerJSCSmoke ? [
        // Smoke check that CJavaScriptCore actually links and the
        // engine evaluates JavaScript end-to-end. CI runs this
        // binary after each build; if it prints `1 + 2 = 3` the
        // toolchain on that platform has a working JSC.
        //
        // Registered only when JSC is reachable on the host (Apple
        // always; non-Apple iff the bun-webkit fetcher has run) so
        // that `swift build` doesn't fail on non-Apple developer
        // machines that haven't fetched the static archive.
        .executableTarget(
            name: "swift-jsc-smoke",
            // Gated off Windows: Bun's `.lib`s are MSVC `/MT` (static
            // CRT) but Swift's runtime is `/MD` (dynamic CRT), and
            // `lld-link` hard-rejects mixing the two with
            // `failifmismatch RuntimeLibrary`. No fix from
            // Package.swift alone — needs either a `/MD` Bun rebuild
            // or a Swift static-stdlib toolchain. The smoke binary's
            // `#if canImport(CJavaScriptCore)` falls through to a
            // skip-message stub on Windows. Tracked in
            // Docs/SwiftJS.md § Cross-platform.
            dependencies: [
                .target(
                    name: "CJavaScriptCore",
                    condition: .when(platforms: [
                        .macOS, .iOS, .tvOS, .watchOS, .visionOS,
                        .linux, .android,
                    ])),
            ],
            path: "Sources/swift-jsc-smoke",
            // The `import CJavaScriptCore` in the smoke binary's
            // Swift source triggers a clang module build of the
            // C target's umbrella header. That clang invocation
            // doesn't always pick up the C target's cSettings, so
            // we also pass `-Xcc -I<abs>` at this consumer's
            // Swift driver level to make the include resolution
            // unambiguous.
            //
            // `.v5` because Swift 6 strict concurrency rejects
            // direct use of the platform's `stderr` global on
            // Linux / Android (Glibc.stderr is a `var`). Matches
            // the language mode the rest of this package runs in.
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(
                    ["-Xcc", "-I\(bunWebKitDir)/include",
                     "-Xcc", "-DSTATICALLY_LINKED_WITH_JavaScriptCore",
                     "-Xcc", "-DSTATICALLY_LINKED_WITH_WTF"],
                    .when(platforms: [.linux, .windows, .android])),
            ]
        ),
    ] : [])
)
