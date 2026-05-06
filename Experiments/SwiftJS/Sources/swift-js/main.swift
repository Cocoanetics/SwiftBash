import Foundation
import SwiftJSCore

// CLI: `swift-js [--sandbox-env] [-e expr | script.js] [args...]`.
// Mirrors `node`'s argv shape so `process.argv[2]` works.
//
// Flags:
//   --sandbox-env   Hide the host process env. JS sees only the
//                   minimal Environment.synthetic set (PATH, HOME,
//                   USER, etc. with placeholder values). Mutations
//                   stay inside the runtime and are not propagated
//                   to setenv().
var raw = CommandLine.arguments
guard raw.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift-js [--sandbox-env] <script.js> [args...]\n".utf8))
    FileHandle.standardError.write(Data("       swift-js [--sandbox-env] -e <expr>\n".utf8))
    exit(2)
}
let interpreter = raw[0]

// Pull out the optional --sandbox-env flag wherever it appears
// before the subcommand.
var sandboxEnv = false
while raw.count >= 2 && raw[1] == "--sandbox-env" {
    sandboxEnv = true
    raw.remove(at: 1)
}

func makeProvider() -> EnvProvider {
    if sandboxEnv {
        // Use SwiftBash's synthetic minimal env — same set the
        // `swift-bash exec --sandbox` mode exposes.
        let synthetic: [String: String] = [
            "PATH":  "/usr/bin:/bin",
            "HOME":  "/home/user",
            "USER":  "user",
            "SHELL": "/bin/sh",
            "TERM":  "dumb",
            "LANG":  "C.UTF-8",
        ]
        return DictionaryEnvProvider(synthetic)
    }
    return OSEnvProvider()
}

let firstArg = raw[1]

// `-e <expr>` evaluates without printing. `-p` evaluates and prints.
if firstArg == "-e" || firstArg == "-p" {
    guard raw.count >= 3 else {
        FileHandle.standardError.write(Data("swift-js: \(firstArg) requires an expression\n".utf8))
        exit(2)
    }
    let expr = raw[2]
    let runtime = JSRuntime(
        argv: [interpreter] + Array(raw.dropFirst(3)),
        envProvider: makeProvider()
    )
    let result = runtime.run(expr, name: "[eval]")
    if firstArg == "-p", runtime.exitCode == 0,
       let result, !result.isUndefined, !result.isNull {
        print(result.toString() ?? "")
    }
    exit(runtime.exitCode)
}

let scriptPath = firstArg
let scriptArgs = Array(raw.dropFirst(2))

// Build argv the way Node does: [interpreter, abs-script-path, ...rest]
let absPath = (scriptPath as NSString).expandingTildeInPath
let argv = [interpreter, absPath] + scriptArgs

let runtime = JSRuntime(argv: argv, envProvider: makeProvider())
do {
    _ = try runtime.runFile(absPath)
} catch {
    FileHandle.standardError.write(Data("swift-js: \(error.localizedDescription)\n".utf8))
    exit(1)
}
exit(runtime.exitCode)
