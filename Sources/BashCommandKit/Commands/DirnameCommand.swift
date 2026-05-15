import ArgumentParser
import BashInterpreter

/// `dirname PATH` — print the directory component of `PATH`.
///
/// ```
/// dirname /tmp/foo.txt  → /tmp
/// dirname /tmp/         → /
/// dirname foo           → .
/// dirname /foo          → /
/// dirname ""            → .
/// ```
public struct DirnameCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "dirname",
        abstract: "Strip the last component from a path."
    )

    @Argument(help: "The path whose directory component to print.")
    public var path: String

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        Shell.bashCurrent.stdout(Self.dirname(of: path) + "\n")
        return .success
    }

    static func dirname(of path: String) -> String {
        if path.isEmpty { return "." }

        var trimmed = path
        // Strip trailing slashes, but keep a single slash if that's all we have.
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed == "/" { return "/" }

        guard let lastSlash = trimmed.lastIndex(of: "/") else { return "." }
        let head = String(trimmed[..<lastSlash])
        // Strip any redundant trailing slashes on the head as well
        // (`/foo/bar` → head `/foo`, but `//foo` → head `/`).
        var result = head
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result.isEmpty ? "/" : result
    }
}
