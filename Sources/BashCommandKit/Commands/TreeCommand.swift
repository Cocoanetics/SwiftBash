import ArgumentParser
import BashInterpreter
import Foundation

/// `tree [DIRECTORY...]` — pretty-print a directory tree.
///
/// - `-L N` / `--level=N` — maximum display depth
/// - `-a` — include hidden entries
/// - `-d` — directories only
/// - `-f` — print full path instead of basename
public struct TreeCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "List contents of directories in a tree-like format."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, DIR…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var maxDepth: Int? = nil
        var showHidden = false
        var dirsOnly = false
        var fullPath = false
        var roots: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { roots.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-L" || a == "--level" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]), n > 0 else {
                    Shell.current.stderr("tree: -L requires a positive integer\n"); return ExitStatus(2)
                }
                maxDepth = n; i += 2; continue
            }
            if a.hasPrefix("--level=") {
                guard let n = Int(a.dropFirst("--level=".count)), n > 0 else {
                    Shell.current.stderr("tree: invalid --level\n"); return ExitStatus(2)
                }
                maxDepth = n; i += 1; continue
            }
            if a == "-a" { showHidden = true; i += 1; continue }
            if a == "-d" { dirsOnly = true; i += 1; continue }
            if a == "-f" { fullPath = true; i += 1; continue }
            if a.hasPrefix("-") && a != "-" && a.count > 1 {
                Shell.current.stderr("tree: unknown option: \(a)\n"); return ExitStatus(2)
            }
            roots.append(a); i += 1
        }
        if roots.isEmpty { roots = ["."] }

        var dirCount = 0
        var fileCount = 0
        for root in roots {
            Shell.current.stdout(root + "\n")
            await walk(root: root, dir: Shell.current.resolvePath(root),
                       prefix: "", depth: 1, maxDepth: maxDepth,
                       showHidden: showHidden, dirsOnly: dirsOnly,
                       fullPath: fullPath, displayPath: root,
                       dirCount: &dirCount, fileCount: &fileCount)
        }
        let summary = dirsOnly
            ? "\n\(dirCount) director\(dirCount == 1 ? "y" : "ies")\n"
            : "\n\(dirCount) director\(dirCount == 1 ? "y" : "ies"), \(fileCount) file\(fileCount == 1 ? "" : "s")\n"
        Shell.current.stdout(summary)
        return .success
    }

    private func walk(root: String, dir: String, prefix: String, depth: Int,
                      maxDepth: Int?, showHidden: Bool, dirsOnly: Bool,
                      fullPath: Bool, displayPath: String,
                      dirCount: inout Int, fileCount: inout Int) async {
        if let m = maxDepth, depth > m { return }
        var entries = (try? await Shell.current.fileSystem.list(dir)) ?? []
        if !showHidden { entries = entries.filter { !$0.hasPrefix(".") } }
        entries.sort()
        var visible: [(name: String, meta: FileMetadata?)] = []
        for n in entries {
            let p = (dir as NSString).appendingPathComponent(n)
            let meta = (try? await Shell.current.fileSystem.metadata(p)) ?? nil
            if dirsOnly && meta?.kind != .directory { continue }
            visible.append((n, meta))
        }
        for (idx, (name, meta)) in visible.enumerated() {
            let isLast = idx == visible.count - 1
            let connector = isLast ? "└── " : "├── "
            let label = fullPath
                ? (displayPath as NSString).appendingPathComponent(name)
                : name
            Shell.current.stdout(prefix + connector + label + "\n")
            if meta?.kind == .directory {
                dirCount += 1
                let childPrefix = prefix + (isLast ? "    " : "│   ")
                let childDir = (dir as NSString).appendingPathComponent(name)
                let childDisplay = (displayPath as NSString).appendingPathComponent(name)
                await walk(root: root, dir: childDir, prefix: childPrefix,
                           depth: depth + 1, maxDepth: maxDepth,
                           showHidden: showHidden, dirsOnly: dirsOnly,
                           fullPath: fullPath, displayPath: childDisplay,
                           dirCount: &dirCount, fileCount: &fileCount)
            } else {
                fileCount += 1
            }
        }
    }
}
