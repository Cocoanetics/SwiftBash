import Foundation
import SwiftJSCore

// Minimal CLI: `swift-js script.js [args...]`. Mirrors `node`'s
// argv shape so a script with `process.argv[2]` works. If the first
// argument is `-` or `-e <expr>` we read from stdin / a one-liner.
let raw = CommandLine.arguments
guard raw.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift-js <script.js> [args...]\n".utf8))
    FileHandle.standardError.write(Data("       swift-js -e <expr>\n".utf8))
    exit(2)
}

let interpreter = raw[0]
let firstArg = raw[1]

// `-e <expr>` evaluates without printing the result (matches `node -e`).
// `-p <expr>` evaluates and prints (matches `node -p`).
if firstArg == "-e" || firstArg == "-p" {
    guard raw.count >= 3 else {
        FileHandle.standardError.write(Data("swift-js: \(firstArg) requires an expression\n".utf8))
        exit(2)
    }
    let expr = raw[2]
    let runtime = JSRuntime(argv: [interpreter] + Array(raw.dropFirst(3)))
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

let runtime = JSRuntime(argv: argv)
do {
    _ = try runtime.runFile(absPath)
} catch {
    FileHandle.standardError.write(Data("swift-js: \(error.localizedDescription)\n".utf8))
    exit(1)
}
exit(runtime.exitCode)
