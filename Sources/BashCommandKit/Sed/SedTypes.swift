import Foundation

/// A sed address: a single line, the last line, a regex, a stepping
/// pattern, or a GNU `+N` relative offset (only valid as the end of a
/// range).
public enum SedAddress: Sendable, Equatable {
    case line(Int)
    case last                                   // $
    case regex(String)                          // /pattern/
    case step(first: Int, step: Int)            // first~step
    case relative(offset: Int)                  // +N (range end only)
}

/// `start[,end][!]`. A bare `start` matches just that address; both
/// endpoints define a range. `negated` flips the membership predicate.
public struct SedAddressRange: Sendable, Equatable {
    public var start: SedAddress?
    public var end: SedAddress?
    public var negated: Bool

    public init(start: SedAddress? = nil, end: SedAddress? = nil, negated: Bool = false) {
        self.start = start
        self.end = end
        self.negated = negated
    }

    public static let none = SedAddressRange()
}

/// One parsed sed script command. Labels and groups are flat in the
/// command list; the executor builds a label index over the same array
/// so branches resolve in O(1).
public indirect enum SedCommandNode: Sendable {
    // Substitute
    case substitute(addr: SedAddressRange,
                    pattern: String, replacement: String,
                    global: Bool, ignoreCase: Bool, printOnMatch: Bool,
                    nthOccurrence: Int?, extendedRegex: Bool,
                    writeFile: String?)

    // Print / delete (cap variants act on first line of pattern space)
    case print(SedAddressRange)
    case printFirstLine(SedAddressRange)
    case delete(SedAddressRange)
    case deleteFirstLine(SedAddressRange)

    // Append / insert / change
    case append(SedAddressRange, text: String)
    case insert(SedAddressRange, text: String)
    case change(SedAddressRange, text: String)

    // Hold space ops
    case hold(SedAddressRange)              // h
    case holdAppend(SedAddressRange)        // H
    case get(SedAddressRange)               // g
    case getAppend(SedAddressRange)         // G
    case exchange(SedAddressRange)          // x

    // Multi-line ops
    case next(SedAddressRange)              // n
    case nextAppend(SedAddressRange)        // N

    // Quit
    case quit(SedAddressRange)              // q
    case quitSilent(SedAddressRange)        // Q

    // Misc
    case transliterate(SedAddressRange, source: String, dest: String)
    case lineNumber(SedAddressRange)        // =
    case zap(SedAddressRange)               // z
    case list(SedAddressRange)              // l
    case printFilename(SedAddressRange)     // F
    case version(SedAddressRange, minVersion: String?)

    // Branching
    case branch(SedAddressRange, label: String?)             // b
    case branchOnSubst(SedAddressRange, label: String?)      // t
    case branchOnNoSubst(SedAddressRange, label: String?)    // T
    case label(name: String)                                 // :name

    // File I/O
    case readFile(SedAddressRange, filename: String)         // r
    case readFileLine(SedAddressRange, filename: String)     // R
    case writeFile(SedAddressRange, filename: String)        // w
    case writeFirstLine(SedAddressRange, filename: String)   // W

    // Disabled in sandbox
    case execute(SedAddressRange, command: String?)          // e

    // Group { ... } — nested commands share addressing
    case group(SedAddressRange, [SedCommandNode])
}

/// Mutable state carried across commands within a single line cycle
/// (and partly across cycles via the executor).
public struct SedExecutionLimits: Sendable {
    public var maxIterations: Int
    public var maxStringLength: Int

    public init(maxIterations: Int = 10_000, maxStringLength: Int = 0) {
        self.maxIterations = maxIterations
        self.maxStringLength = maxStringLength
    }
}

/// Range tracking is keyed by a stable serialization of the
/// `start,end` pair so `/a/,/b/` keeps separate state per occurrence.
struct SedRangeState {
    var active: Bool = false
    var startLine: Int = 0
    var completed: Bool = false
}

/// Error type from parsing a sed script.
public struct SedScriptError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
