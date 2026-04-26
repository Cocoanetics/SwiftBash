import ArgumentParser
import BashInterpreter

/// `basename PATH [SUFFIX]` — print the file-name component of `PATH`.
///
/// Trailing slashes are stripped, then everything up to and including
/// the last `/` is removed. With `SUFFIX`, the suffix is also stripped
/// from the end — but only when it's a proper suffix (the whole result
/// isn't equal to the suffix).
///
/// ```
/// basename /tmp/foo.txt       → foo.txt
/// basename /tmp/foo.txt .txt  → foo
/// basename /tmp/              → tmp
/// basename /                  → /
/// ```
public struct BasenameCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "basename",
        abstract: "Strip directory and (optional) suffix from a path."
    )

    @Argument(help: "The path whose basename to print.")
    public var path: String

    @Argument(help: "Optional suffix to strip from the result.")
    public var suffix: String?

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        Shell.current.stdout(Self.basename(of: path, suffix: suffix ?? "") + "\n")
        return .success
    }

    static func basename(of path: String, suffix: String) -> String {
        if path.isEmpty { return "" }
        var result = path
        // Strip trailing slashes, but keep a single slash if that's all we have.
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        // Path consisting entirely of slashes → "/".
        if result == "/" { return "/" }
        if let lastSlash = result.lastIndex(of: "/") {
            result = String(result[result.index(after: lastSlash)...])
        }
        if !suffix.isEmpty, result != suffix, result.hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
        }
        return result
    }
}
