import Foundation

/// Runtime state for an AWK program. Owns built-in variables, user
/// variables, arrays, fields, and control-flow flags. The interpreter
/// keeps a single instance for the whole run so getline / END blocks
/// see the right NR / FILENAME / hold-space.
public final class AwkContext: @unchecked Sendable {
    // built-in scalars
    public var FS: String = " "
    public var OFS: String = " "
    public var ORS: String = "\n"
    public var OFMT: String = "%.6g"
    public var NR: Int = 0
    public var NF: Int = 0
    public var FNR: Int = 0
    public var FILENAME: String = ""
    public var RSTART: Int = 0
    public var RLENGTH: Int = -1
    public var SUBSEP: String = "\u{1c}"

    // current line and split fields
    public var line: String = ""
    public var fields: [String] = []

    // user vars + arrays
    public var vars: [String: AwkValue] = [:]
    public var arrays: [String: AwkArray] = [:]
    /// Function-parameter array aliases. When `f(a)` is called with a
    /// scalar arg name `a`, we record `param→a` here so reads/writes
    /// inside the function go to the original array (pass-by-ref).
    public var arrayAliases: [String: String] = [:]

    // ARGC / ARGV / ENVIRON
    public var ARGC: Int = 0
    public var ARGV: AwkArray = AwkArray()
    public var ENVIRON: AwkArray = AwkArray()

    // user-defined functions (registered before any execution)
    public var functions: [String: AwkFunction] = [:]

    // current input — used by `getline`
    public var lines: [String] = []
    public var lineIndex: Int = -1

    // control flow
    public var exitCode: Int = 0
    public var shouldExit = false
    public var shouldNext = false
    public var shouldNextFile = false
    public var loopBreak = false
    public var loopContinue = false
    public var hasReturn = false
    public var returnValue: AwkValue = .empty
    public var inEndBlock = false

    // limits
    public var maxIterations: Int = 1_000_000
    public var maxRecursionDepth: Int = 200
    public var currentRecursionDepth: Int = 0

    // output sinks (buffer + per-file caches)
    public var output = ""
    public var openedFiles = Set<String>()
    public var fileWrites: [String: String] = [:]            // file path → accumulated bytes
    public var pipeOutputs: [String: String] = [:]            // command → accumulated bytes (sink)

    // file/pipe getline read state
    public var fileLines: [String: [String]] = [:]
    public var fileLineIndex: [String: Int] = [:]

    // random state for srand
    public var randomState: UInt64 = 1

    // cwd + injected file IO closure (set by AwkCommand)
    public var cwd: String = "."
    public var readFile: (String) throws -> String = { _ in throw AwkRuntimeError("file IO not configured") }
    public var resolvePath: (String, String) -> String = { cwd, p in
        p.hasPrefix("/") ? p : "\(cwd)/\(p)"
    }

    public init() {}
}
