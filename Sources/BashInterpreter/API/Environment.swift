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
    /// Indexed array variables, parallel to `variables`. A name in
    /// `arrays` masks the same name in `variables` for `${name[...]}`
    /// references. Bare `${name}` reads element 0 (matching bash's
    /// "an unsubscripted array reference is element 0" rule).
    public var arrays: [String: [String]]
    public var workingDirectory: String

    public init(variables: [String: String] = [:],
                arrays: [String: [String]] = [:],
                workingDirectory: String = FileManager.default.currentDirectoryPath)
    {
        self.variables = variables
        self.arrays = arrays
        self.workingDirectory = workingDirectory
    }

    /// Read/write a variable by name. Reading a name that's an array
    /// returns its first element; writing replaces *both* the array
    /// (cleared) and the scalar value.
    public subscript(name: String) -> String? {
        get {
            if let arr = arrays[name] {
                return arr.first ?? ""
            }
            return variables[name]
        }
        set {
            // Scalar assignment to an array name removes the array.
            arrays.removeValue(forKey: name)
            variables[name] = newValue
        }
    }

    /// A snapshot of the host process's environment and cwd.
    public static func current() -> Environment {
        Environment(variables: ProcessInfo.processInfo.environment,
                    workingDirectory: FileManager.default.currentDirectoryPath)
    }
}
