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
            Shell.current.stderr("\(name): filename argument required\n")
            return ExitStatus(2)
        }
        let data: Data
        do {
            data = try await Shell.current.readDataAtPath(path)
        } catch FileSystemError.notFound {
            Shell.current.stderr("\(name): \(path): No such file or directory\n")
            return .failure
        }
        let source = String(decoding: data, as: UTF8.self)

        // Save call-frame state — same shape as a function call so
        // `return` works and the positional params don't leak.
        let savedParams = Shell.current.positionalParameters
        let savedSource = Shell.current.currentSource

        // `source PATH a b c` → the sourced script sees `a b c` as $1..$3.
        let extraArgs = Array(argv.dropFirst(2))
        if !extraArgs.isEmpty {
            Shell.current.positionalParameters = extraArgs
        }
        Shell.current.functionCallDepth += 1
        Shell.current.localVarStack.append([])

        defer {
            if let frame = Shell.current.localVarStack.popLast() {
                for (name, prior) in frame.reversed() {
                    Shell.current.environment[name] = prior
                }
            }
            Shell.current.functionCallDepth -= 1
            Shell.current.positionalParameters = savedParams
            Shell.current.currentSource = savedSource
        }

        do {
            return try await Shell.current.run(source)
        } catch let ret as ReturnSignal {
            return ret.status
        }
    }
}
