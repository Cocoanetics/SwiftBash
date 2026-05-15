import ArgumentParser
import BashInterpreter
import Foundation

/// `du [OPTIONS] [PATH...]` — display disk usage.
///
/// Prints a size and path per line, summing into directories. With
/// `-a`, also lists individual files. With `-s`, prints only the
/// summary for each PATH. Sizes are 1024-byte blocks by default;
/// `-h` shows human-readable units; `-b` shows raw bytes; `-k`
/// (default) and `-m` switch the divisor.
public struct DuCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "du",
        abstract: "Estimate file space usage."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, PATH…")
    public var rawArgv: [String] = []

    public init() {}

    private enum Unit { case bytes, kib, mib, human }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        var unit: Unit = .kib
        var summarize = false
        var allFiles = false
        var maxDepth: Int?
        var paths: [String] = []
        // Expand combined short-flag bundles like `-sh` into
        // `-s -h` before the main parse loop. Real `du` accepts
        // both `du -sh path` and `du -s -h path`; without this
        // pre-pass our exact-match per-token check failed on the
        // combined form with `du: unknown option: -sh`.
        let booleanShortFlags: Set<Character> = ["s", "a", "h", "b", "k", "m"]
        let argv: [String] = rawArgv.flatMap { (token: String) -> [String] in
            guard token.hasPrefix("-"),
                  !token.hasPrefix("--"),
                  token.count > 2
            else { return [token] }
            let chars = Array(token.dropFirst())
            if chars.allSatisfy({ booleanShortFlags.contains($0) }) {
                return chars.map { "-\($0)" }
            }
            return [token]
        }
        var idx = 0
        while idx < argv.count {
            let arg = argv[idx]
            if arg == "--" {
                idx += 1
                while idx < rawArgv.count { paths.append(rawArgv[idx]); idx += 1 }
                break
            }
            if arg == "-s" || arg == "--summarize" { summarize = true; idx += 1; continue }
            if arg == "-a" || arg == "--all" { allFiles = true; idx += 1; continue }
            if arg == "-h" || arg == "--human-readable" { unit = .human; idx += 1; continue }
            if arg == "-b" || arg == "--bytes" { unit = .bytes; idx += 1; continue }
            if arg == "-k" { unit = .kib; idx += 1; continue }
            if arg == "-m" { unit = .mib; idx += 1; continue }
            if arg == "-d" || arg == "--max-depth" {
                guard idx + 1 < rawArgv.count, let num = Int(rawArgv[idx + 1]) else {
                    Shell.bashCurrent.stderr("du: -d requires N\n"); return ExitStatus(2)
                }
                maxDepth = num; idx += 2; continue
            }
            if arg.hasPrefix("--max-depth=") {
                guard let num = Int(arg.dropFirst("--max-depth=".count)) else {
                    Shell.bashCurrent.stderr("du: invalid --max-depth\n"); return ExitStatus(2)
                }
                maxDepth = num; idx += 1; continue
            }
            if arg.hasPrefix("-") && arg != "-" && arg.count > 1 {
                Shell.bashCurrent.stderr("du: unknown option: \(arg)\n"); return ExitStatus(2)
            }
            paths.append(arg); idx += 1
        }
        if paths.isEmpty { paths = ["."] }

        var hadError = false
        for path in paths {
            let resolved = Shell.bashCurrent.resolvePath(path)
            do {
                let options = WalkOptions(unit: unit,
                                          maxDepth: summarize ? 0 : maxDepth,
                                          allFiles: allFiles,
                                          summarize: summarize)
                let total = try await walk(displayPath: path, abs: resolved,
                                           depth: 0, options: options)
                if summarize {
                    Shell.bashCurrent.stdout("\(formatSize(total, unit: unit))\t\(path)\n")
                }
            } catch {
                Shell.bashCurrent.stderr("du: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    /// Bundle of long-lived walk parameters; keeps `walk` under the
    /// function-parameter-count limit.
    private struct WalkOptions {
        let unit: Unit
        let maxDepth: Int?
        let allFiles: Bool
        let summarize: Bool
    }

    private func walk(displayPath: String, abs: String, depth: Int,
                      options: WalkOptions) async throws -> Int64 {
        try Task.checkCancellation()
        guard let meta = try await Shell.bashCurrent.fileSystem.metadata(abs) else {
            throw FileSystemError.notFound(abs)
        }
        if meta.kind != .directory {
            if options.allFiles && !options.summarize {
                Shell.bashCurrent.stdout("\(formatSize(meta.size, unit: options.unit))\t\(displayPath)\n")
            }
            return meta.size
        }
        var total: Int64 = 0
        let entries = ((try? await Shell.bashCurrent.fileSystem.list(abs)) ?? [])
            .map(\.name)
        for name in entries.sorted() {
            let childAbs = (abs as NSString).appendingPathComponent(name)
            let childDisplay = displayPath == "." ? "./\(name)"
                : (displayPath as NSString).appendingPathComponent(name)
            total += try await walk(displayPath: childDisplay, abs: childAbs,
                                    depth: depth + 1, options: options)
        }
        if !options.summarize {
            let withinDepth = (options.maxDepth.map { depth <= $0 } ?? true)
            if withinDepth {
                Shell.bashCurrent.stdout("\(formatSize(total, unit: options.unit))\t\(displayPath)\n")
            }
        }
        return total
    }

    private func formatSize(_ bytes: Int64, unit: Unit) -> String {
        switch unit {
        case .bytes: return String(bytes)
        case .kib: return String((bytes + 1023) / 1024)
        case .mib: return String((bytes + 1024 * 1024 - 1) / (1024 * 1024))
        case .human: return humanReadable(bytes)
        }
    }

    private func humanReadable(_ bytes: Int64) -> String {
        let num = Double(bytes)
        let kib = 1024.0
        if num < kib { return "\(bytes)B" }
        if num < kib * kib {
            let val = num / kib
            return val < 10 ? String(format: "%.1fK", val) : "\(Int(val.rounded()))K"
        }
        if num < kib * kib * kib {
            let val = num / (kib * kib)
            return val < 10 ? String(format: "%.1fM", val) : "\(Int(val.rounded()))M"
        }
        let val = num / (kib * kib * kib)
        return val < 10 ? String(format: "%.1fG", val) : "\(Int(val.rounded()))G"
    }
}
