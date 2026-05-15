import ArgumentParser
import BashInterpreter
import Foundation

/// `bc [-l] [FILE...]` — arbitrary-precision calculator.
///
/// Reads expressions from stdin (one per line) or FILEs and prints
/// the result of each. Uses Swift `Double` internally (so this isn't
/// truly arbitrary-precision, but matches the practical use case of
/// shell scripts piping `echo "..." | bc`).
///
/// Supported:
/// - operators: `+ - * / % ^` (^ is exponentiation)
/// - comparison: `== != < <= > >=` (return 1 / 0)
/// - logical: `! && ||`
/// - parentheses, unary `-`/`+`
/// - assignment: `var = expr` (variable persists for the session)
/// - functions: `sqrt(x)`, `length(x)` (digit count of integer part),
///   `scale(x)` (return scale value), and the math-lib trig fns
///   `s(x)` `c(x)` `a(x)` `l(x)` `e(x)` (with `-l`).
/// - `scale = N` controls decimals shown for division.
/// - `quit` / `halt` exits.
/// - `# comment` and `/* ... */` are stripped.
public struct BcCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "bc",
        abstract: "Arbitrary-precision calculator language."
    )

    @Flag(name: [.customShort("l"), .customLong("mathlib")],
          help: "Define math library: s c a l e and set scale=20.")
    public var mathlib: Bool = false

    @Flag(name: [.customShort("q"), .customLong("quiet")],
          help: "Don't print the GNU bc welcome banner (we never do).")
    public var quiet: Bool = false

    @Argument(help: "Files to evaluate before reading stdin.")
    public var files: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var ctx = BcCalculator.Context()
        if mathlib { ctx.scale = 20 }

        for file in files {
            do {
                let data = try await Shell.bashCurrent.readDataAtPath(file)
                guard let text = String(bytes: data, encoding: .utf8) else {
                    Shell.bashCurrent.stderr("bc: \(file): invalid UTF-8\n")
                    return .failure
                }
                if let exit = process(text, ctx: &ctx) {
                    return exit
                }
            } catch {
                Shell.bashCurrent.stderr("bc: \(file): \(error)\n")
                return .failure
            }
        }
        let stdin = await Shell.bashCurrent.stdin.readAllString()
        if !stdin.isEmpty {
            if let exit = process(stdin, ctx: &ctx) {
                return exit
            }
        }
        return .success
    }

    /// Process a chunk of bc input. Returns a non-nil status if the
    /// program should exit (e.g., on `quit`).
    private func process(_ text: String, ctx: inout BcCalculator.Context) -> ExitStatus? {
        let stripped = BcCalculator.stripComments(text)
        for raw in stripped.components(separatedBy: "\n") {
            // Real bc accepts multiple statements per line separated
            // by `;` (e.g. `scale=4; 22/7`). Split here so each
            // statement reaches `evalLine` independently.
            for stmt in raw.split(separator: ";", omittingEmptySubsequences: true) {
                let line = stmt.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line == "quit" || line == "halt" { return .success }
                do {
                    if let result = try BcCalculator.evalLine(line, ctx: &ctx) {
                        Shell.bashCurrent.stdout(
                            BcCalculator.format(result, scale: ctx.scale) + "\n")
                    }
                } catch let bcError as BcCalculator.Error {
                    Shell.bashCurrent.stderr("bc: \(bcError.message)\n")
                } catch {
                    Shell.bashCurrent.stderr("bc: \(error)\n")
                }
            }
        }
        return nil
    }
}

enum BcCalculator {
    struct Context {
        var vars: [String: Double] = [:]
        var scale: Int = 0
    }
    struct Error: Swift.Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Evaluate one bc statement. Returns the value to print, or nil
    /// for assignments / scale settings (which are silent).
    static func evalLine(_ line: String, ctx: inout Context) throws -> Double? {
        var parser = Parser(input: line, ctx: ctx)
        let result = try parser.parseTopLevel()
        ctx = parser.ctx
        return result
    }

    /// Format a Double the way bc does: integers without a decimal,
    /// otherwise truncated (not rounded) to `scale` digits.
    static func format(_ value: Double, scale: Int) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value > 0 ? "inf" : "-inf" }
        if scale == 0 || value == value.rounded(.towardZero) {
            return String(Int64(value.rounded(.towardZero)))
        }
        // Truncate to `scale` decimals.
        let mult = pow(10.0, Double(scale))
        let truncated = (value * mult).rounded(.towardZero) / mult
        var str = String(format: "%.\(scale)f", truncated)
        // Strip trailing zeros, but keep at least one digit after `.`.
        if str.contains(".") {
            while str.hasSuffix("0") { str.removeLast() }
            if str.hasSuffix(".") { str.removeLast() }
        }
        return str
    }

    /// Strip `/* ... */` block comments and `# ...` line comments from
    /// bc input, mirroring GNU bc's tokenizer.
    static func stripComments(_ text: String) -> String {
        var stripped = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "/", text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "*" {
                // Skip until "*/".
                index = text.index(index, offsetBy: 2)
                while index < text.endIndex {
                    if text[index] == "*", text.index(after: index) < text.endIndex,
                       text[text.index(after: index)] == "/" {
                        index = text.index(index, offsetBy: 2); break
                    }
                    index = text.index(after: index)
                }
                continue
            }
            if char == "#" {
                while index < text.endIndex && text[index] != "\n" {
                    index = text.index(after: index)
                }
                continue
            }
            stripped.append(char)
            index = text.index(after: index)
        }
        return stripped
    }
}
