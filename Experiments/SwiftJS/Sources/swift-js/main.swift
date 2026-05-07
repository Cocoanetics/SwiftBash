import Foundation
import SwiftJSCore

#if !canImport(JavaScriptCore)
// JavaScriptCore is Apple-only. On Linux / Windows / Android the
// SwiftJSCore module compiles to nothing useful (its types are
// gated on `canImport(JavaScriptCore)`), so the executable can't
// run JS. Print a clear message and exit instead of confusing
// build failures.
FileHandle.standardError.write(Data(
    "swift-js: JavaScriptCore is not available on this platform.\n".utf8
))
FileHandle.standardError.write(Data(
    "          Apple platforms (macOS, iOS, tvOS, watchOS) are supported.\n".utf8
))
FileHandle.standardError.write(Data(
    "          For Linux / Windows we'd need a different engine\n".utf8
))
FileHandle.standardError.write(Data(
    "          (e.g. QuickJS-NG); see Docs/SwiftJS.md.\n".utf8
))
exit(78)  // EX_CONFIG
#else

// Multi-call binary. The basename of argv[0] selects the personality:
//
//     node      — accept `node script.js [args...]`, `node -e <expr>`,
//                 `node -p <expr>`, `node --version`. A `.js` file
//                 with `#!/usr/bin/env node` invokes whichever
//                 binary is first on PATH — install ours as `node`
//                 (or symlink it) and existing scripts run unchanged.
//
//     bun       — same shape; `bun -e`, `bun --print`, `bun script.js`.
//                 We don't ship Bun's superset APIs (Bun.file etc.),
//                 but argv-shape and exit-code semantics match.
//
//     swift-js  — our own canonical name. Adds `--sandbox-env` and
//                 `install` subcommands.
//
// Internally there is one runtime; only the CLI surface differs.

let raw = CommandLine.arguments
guard !raw.isEmpty else { exit(2) }
let interpreter = raw[0]
let invokedAs = (interpreter as NSString).lastPathComponent.lowercased()
let isNodeAlias = invokedAs == "node" || invokedAs == "nodejs"
let isBunAlias  = invokedAs == "bun"
let isAlias     = isNodeAlias || isBunAlias

// `swift-js install <prefix>` creates `node`, `bun`, and `swift-js`
// symlinks pointing at this binary so existing shebangs find us.
if !isAlias, raw.count >= 2, raw[1] == "install" {
    let prefix = raw.count >= 3
        ? raw[2]
        : (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")
    installAliases(prefix: prefix, source: interpreter)
    exit(0)
}

guard raw.count >= 2 else {
    let usage = isAlias
        ? "usage: \(invokedAs) <script.js> [args...]\n       \(invokedAs) -e <expr>\n       \(invokedAs) --version\n"
        : "usage: swift-js [--sandbox-env] <script.js> [args...]\n       swift-js [--sandbox-env] -e|-p <expr>\n       swift-js install [prefix]\n       swift-js --version\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

// Pull off optional `--sandbox-env` (swift-js only).
var args = Array(raw.dropFirst())
var sandboxEnv = false
if !isAlias, args.first == "--sandbox-env" {
    sandboxEnv = true
    args.removeFirst()
}

// Common flags
if args.first == "--version" || args.first == "-v" {
    let version = isNodeAlias ? "v22.0.0-swiftjs"
                : isBunAlias  ? "1.3.0-swiftjs"
                              : "swift-js 0.2"
    print(version)
    exit(0)
}

func makeProvider() -> EnvProvider {
    if sandboxEnv {
        return DictionaryEnvProvider([
            "PATH": "/usr/bin:/bin", "HOME": "/home/user", "USER": "user",
            "SHELL": "/bin/sh", "TERM": "dumb", "LANG": "C.UTF-8",
        ])
    }
    return OSEnvProvider()
}

let firstArg = args[0]

// `-e <expr>` is shared. node's `-p` and bun's `--print` both
// evaluate-and-print; we accept both.
if firstArg == "-e" || firstArg == "-p" || firstArg == "--print" {
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("\(invokedAs): \(firstArg) requires an expression\n".utf8))
        exit(2)
    }
    let expr = args[1]
    let runtime = JSRuntime(
        argv: [interpreter] + Array(args.dropFirst(2)),
        envProvider: makeProvider()
    )
    let result = runtime.run(expr, name: "[eval]")
    let shouldPrint = (firstArg == "-p" || firstArg == "--print")
    if shouldPrint, runtime.exitCode == 0,
       let result, !result.isUndefined, !result.isNull {
        print(result.toString() ?? "")
    }
    runtime.fireExitListeners()
    exit(runtime.exitCode)
}

let scriptPath = firstArg
let scriptArgs = Array(args.dropFirst())
let absPath = (scriptPath as NSString).expandingTildeInPath
let argv = [interpreter, absPath] + scriptArgs

let runtime = JSRuntime(argv: argv, envProvider: makeProvider())
do {
    _ = try runtime.runFile(absPath)
} catch {
    FileHandle.standardError.write(Data("\(invokedAs): \(error.localizedDescription)\n".utf8))
    exit(1)
}
exit(runtime.exitCode)


// MARK: - install subcommand

func installAliases(prefix: String, source: String) {
    let fm = FileManager.default
    let absSource = (source as NSString).standardizingPath
    do {
        try fm.createDirectory(atPath: prefix, withIntermediateDirectories: true)
        // Resolve to an absolute path so symlinks work from anywhere.
        let resolvedSource: String = {
            if absSource.hasPrefix("/") { return absSource }
            return fm.currentDirectoryPath + "/" + absSource
        }()
        for name in ["swift-js", "node", "bun"] {
            let target = (prefix as NSString).appendingPathComponent(name)
            try? fm.removeItem(atPath: target)
            try fm.createSymbolicLink(atPath: target, withDestinationPath: resolvedSource)
            print("→ \(target)  →  \(resolvedSource)")
        }
        print("\nAdd to PATH:")
        print("  export PATH=\"\(prefix):$PATH\"")
    } catch {
        FileHandle.standardError.write(Data("install failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

#endif
