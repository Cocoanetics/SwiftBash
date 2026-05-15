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

    private struct WalkOptions {
        let maxDepth: Int?
        let showHidden: Bool
        let dirsOnly: Bool
        let fullPath: Bool
    }

    private struct WalkCounters {
        var dirCount: Int
        var fileCount: Int
    }

    private struct WalkFrame {
        let root: String
        let dir: String
        let prefix: String
        let depth: Int
        let displayPath: String
    }

    // `tree` argument parsing covers short, long, `=` flag forms; the
    // table is intrinsically wide.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        var maxDepth: Int?
        var showHidden = false
        var dirsOnly = false
        var fullPath = false
        var roots: [String] = []
        var idx = 0
        while idx < rawArgv.count {
            let arg = rawArgv[idx]
            if arg == "--" {
                idx += 1
                while idx < rawArgv.count { roots.append(rawArgv[idx]); idx += 1 }
                break
            }
            if arg == "-L" || arg == "--level" {
                guard idx + 1 < rawArgv.count,
                      let value = Int(rawArgv[idx + 1]), value > 0 else {
                    Shell.bashCurrent.stderr("tree: -L requires a positive integer\n")
                    return ExitStatus(2)
                }
                maxDepth = value; idx += 2; continue
            }
            if arg.hasPrefix("--level=") {
                guard let value = Int(arg.dropFirst("--level=".count)), value > 0 else {
                    Shell.bashCurrent.stderr("tree: invalid --level\n"); return ExitStatus(2)
                }
                maxDepth = value; idx += 1; continue
            }
            if arg == "-a" { showHidden = true; idx += 1; continue }
            if arg == "-d" { dirsOnly = true; idx += 1; continue }
            if arg == "-f" { fullPath = true; idx += 1; continue }
            if arg.hasPrefix("-") && arg != "-" && arg.count > 1 {
                Shell.bashCurrent.stderr("tree: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            roots.append(arg); idx += 1
        }
        if roots.isEmpty { roots = ["."] }

        var counters = WalkCounters(dirCount: 0, fileCount: 0)
        let options = WalkOptions(
            maxDepth: maxDepth, showHidden: showHidden,
            dirsOnly: dirsOnly, fullPath: fullPath)
        for root in roots {
            Shell.bashCurrent.stdout(root + "\n")
            let frame = WalkFrame(
                root: root, dir: Shell.bashCurrent.resolvePath(root),
                prefix: "", depth: 1, displayPath: root)
            await walk(frame: frame, options: options, counters: &counters)
        }
        let dirNoun = counters.dirCount == 1 ? "y" : "ies"
        let fileNoun = counters.fileCount == 1 ? "" : "s"
        let summary = dirsOnly
            ? "\n\(counters.dirCount) director\(dirNoun)\n"
            : "\n\(counters.dirCount) director\(dirNoun), "
              + "\(counters.fileCount) file\(fileNoun)\n"
        Shell.bashCurrent.stdout(summary)
        return .success
    }

    private func walk(frame: WalkFrame, options: WalkOptions,
                      counters: inout WalkCounters) async {
        // Honour cooperative cancel — the walk is non-throwing, so we
        // can't use checkCancellation; bail explicitly.
        if Task.isCancelled { return }
        if let max = options.maxDepth, frame.depth > max { return }
        var entries = (try? await Shell.bashCurrent.fileSystem.list(frame.dir)) ?? []
        if !options.showHidden { entries = entries.filter { !$0.name.hasPrefix(".") } }
        entries.sort { $0.name < $1.name }
        let visible: [(name: String, meta: FileMetadata?)] = entries.compactMap {
            if options.dirsOnly && $0.metadata.kind != .directory { return nil }
            return (name: $0.name, meta: $0.metadata)
        }
        for (slot, (name, meta)) in visible.enumerated() {
            let isLast = slot == visible.count - 1
            let connector = isLast ? "└── " : "├── "
            let label = options.fullPath
                ? (frame.displayPath as NSString).appendingPathComponent(name)
                : name
            Shell.bashCurrent.stdout(frame.prefix + connector + label + "\n")
            if meta?.kind == .directory {
                counters.dirCount += 1
                let childFrame = WalkFrame(
                    root: frame.root,
                    dir: (frame.dir as NSString).appendingPathComponent(name),
                    prefix: frame.prefix + (isLast ? "    " : "│   "),
                    depth: frame.depth + 1,
                    displayPath: (frame.displayPath as NSString).appendingPathComponent(name))
                await walk(frame: childFrame, options: options, counters: &counters)
            } else {
                counters.fileCount += 1
            }
        }
    }
}
