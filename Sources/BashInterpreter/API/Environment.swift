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
    /// Indexed array variables — *sparse* by design, just like bash:
    /// `arr[5]=x` on a fresh name leaves indices 0–4 unset rather
    /// than padding with empty strings. `${arr[@]}` skips gaps.
    public var arrays: [String: BashArray]
    /// Associative arrays (bash `declare -A`) — name → (key → value).
    /// A name in this dict masks both `arrays` and `variables` for
    /// subscripted reads.
    public var associativeArrays: [String: [String: String]]
    public var workingDirectory: String

    public init(variables: [String: String] = [:],
                arrays: [String: BashArray] = [:],
                associativeArrays: [String: [String: String]] = [:],
                workingDirectory: String = FileManager.default.currentDirectoryPath)
    {
        self.variables = variables
        self.arrays = arrays
        self.associativeArrays = associativeArrays
        self.workingDirectory = workingDirectory
    }

    /// Read/write a variable by name. Reading an array name returns
    /// its element-0 (matching bash's "bare reference reads index 0"
    /// rule); writing replaces both the array (cleared) and any
    /// scalar with the same name.
    public subscript(name: String) -> String? {
        get {
            if let arr = arrays[name] {
                return arr[0] ?? ""
            }
            return variables[name]
        }
        set {
            arrays.removeValue(forKey: name)
            variables[name] = newValue
        }
    }

    /// A snapshot of the host process's environment and cwd.
    /// Use only when the embedder genuinely wants the host's vars
    /// surfaced to the script — typically the `swift-bash exec` CLI
    /// in non-sandbox mode.
    public static func current() -> Environment {
        Environment(variables: ProcessInfo.processInfo.environment,
                    workingDirectory: FileManager.default.currentDirectoryPath)
    }

    /// A minimal environment that exposes nothing about the host.
    /// Pre-populated with the small set of variables most scripts
    /// expect to find (using ``HostInfo/synthetic``-aligned values).
    /// Cwd defaults to `"/"`; callers usually override.
    public static func synthetic(
        hostInfo: HostInfo = .synthetic,
        workingDirectory: String = "/"
    ) -> Environment {
        let vars: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/home/\(hostInfo.userName)",
            "USER": hostInfo.userName,
            "LOGNAME": hostInfo.userName,
            "SHELL": "/bin/sh",
            "TERM": "dumb",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
        ]
        return Environment(variables: vars,
                           workingDirectory: workingDirectory)
    }
}

/// A sparse indexed array — `[Int: String]` plus convenience accessors
/// that hide the storage choice from callers.
///
/// Bash arrays are sparse: `arr[5]=x` on an empty name sets index 5
/// only, leaving 0–4 unset. `${arr[@]}` then yields `["x"]` — gaps
/// disappear. Most callers want one of: an indexed read, the sorted
/// list of *set* indices, or the values in index order.
public struct BashArray: Hashable, Sendable {
    public private(set) var entries: [Int: String]

    public init() { self.entries = [:] }
    public init(entries: [Int: String]) { self.entries = entries }

    /// Build a dense array from a Swift `[String]` — indices 0..count-1.
    public init(dense values: [String]) {
        var dict: [Int: String] = [:]
        for (i, v) in values.enumerated() { dict[i] = v }
        self.entries = dict
    }

    /// Number of *set* slots. `arr[5]=x` on a fresh array gives 1,
    /// not 6 — matches `${#arr[@]}` semantics.
    public var count: Int { entries.count }

    /// Sorted indices of set slots (for `${!arr[@]}`).
    public var sortedIndices: [Int] { entries.keys.sorted() }

    /// All values in sorted-index order (for `${arr[@]}`).
    public var elementsInOrder: [String] {
        sortedIndices.compactMap { entries[$0] }
    }

    /// Indexed access — `nil` when the slot isn't set.
    public subscript(index: Int) -> String? {
        get { entries[index] }
        set { entries[index] = newValue }
    }

    /// Append values starting at `(maxIndex + 1)`. Empty array
    /// appends starting at 0, matching bash.
    public mutating func append(_ values: [String]) {
        var next = (entries.keys.max() ?? -1) + 1
        for v in values {
            entries[next] = v
            next += 1
        }
    }
}
