import Foundation

/// The shell's execution environment: variables and working directory.
///
/// Currently tracks:
/// - `variables`: a flat dictionary of name → value pairs. In real bash
///   some variables are "exported" and some aren't; this skeleton treats
///   every variable as exported (the distinction only matters once we
///   spawn subprocesses).
/// - `workingDirectory`: the shell's virtual cwd. Changing it via `cd`
///   affects the shell's notion of `$PWD` but does not `chdir` the host
///   process — builtins stay self-contained.
public struct Environment: Hashable, Sendable {
    public var variables: [String: String]
    public var workingDirectory: String

    public init(variables: [String: String] = [:],
                workingDirectory: String = FileManager.default.currentDirectoryPath)
    {
        self.variables = variables
        self.workingDirectory = workingDirectory
    }

    /// Read/write a variable by name.
    public subscript(name: String) -> String? {
        get { variables[name] }
        set { variables[name] = newValue }
    }

    /// A snapshot of the host process's environment and cwd.
    public static func current() -> Environment {
        Environment(variables: ProcessInfo.processInfo.environment,
                    workingDirectory: FileManager.default.currentDirectoryPath)
    }
}
