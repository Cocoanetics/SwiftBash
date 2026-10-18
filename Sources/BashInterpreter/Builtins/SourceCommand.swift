import Foundation
import BashSyntax

/// `source PATH [ARGS…]` (also spelled `.`) — read and execute the
/// file's contents in the *current* shell. Variables and function
/// definitions made by the sourced script persist.
///
/// Extra args become the sourced script's positional parameters
/// (`$1`, `$2`, …) for its duration; the caller's positional params
/// are restored on completion. Like a function call, `return N`
/// works inside the sourced script and unwinds back to the caller.
public struct SourceCommand: Command {
    public let name: String
    public init(name: String = "source") { self.name = name }

    public func run(_ argv: [String]) async throws -> ExitStatus {
        guard let path = argv.dropFirst().first else {
            Shell.bashCurrent.stderr("\(name): filename argument required\n")
            return ExitStatus(2)
        }
        let data: Data
        do {
            data = try await Shell.bashCurrent.readDataAtPath(path)
        } catch FileSystemError.notFound {
            Shell.bashCurrent.stderr("\(name): \(path): No such file or directory\n")
            return .failure
        }
        // Sourced scripts may contain arbitrary bytes; tolerate non-UTF-8.
        // swiftlint:disable:next optional_data_string_conversion
        let source = String(decoding: data, as: UTF8.self)

        // `BASH_SOURCE` / `BASH_LINENO` frame (`FUNCNAME` shows it as
        // `source`), with the caller's line.
        let frame = CallFrame(name: "source", file: path,
                              callLine: Shell.bashCurrent.currentLineNumber)

        // Save call-frame state — same shape as a function call so
        // `return` works and the positional params don't leak.
        let savedParams = Shell.bashCurrent.positionalParameters
        let savedSource = Shell.bashCurrent.currentSource
        let savedLineOffset = Shell.bashCurrent.dynamicVariables.lineOffset
        // The file's own lines count from 1.
        Shell.bashCurrent.dynamicVariables.lineOffset = 0

        // `source PATH a b c` → the sourced script sees `a b c` as $1..$3.
        let extraArgs = Array(argv.dropFirst(2))
        if !extraArgs.isEmpty {
            Shell.bashCurrent.positionalParameters = extraArgs
        }
        Shell.bashCurrent.functionCallDepth += 1
        Shell.bashCurrent.localVarStack.append([])

        defer {
            if let frame = Shell.bashCurrent.localVarStack.popLast() {
                for (name, prior) in frame.reversed() {
                    Shell.bashCurrent.environment[name] = prior
                }
            }
            Shell.bashCurrent.functionCallDepth -= 1
            Shell.bashCurrent.positionalParameters = savedParams
            Shell.bashCurrent.currentSource = savedSource
            Shell.bashCurrent.dynamicVariables.lineOffset = savedLineOffset
        }

        return try await Shell.bashCurrent.withCallFrame(frame) {
            do {
                return try await Shell.bashCurrent.run(source)
            } catch let ret as ReturnSignal {
                return ret.status
            }
        }
    }
}
