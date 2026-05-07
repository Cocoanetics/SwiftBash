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

    public mutating func execute() async throws -> ExitStatus {
        var unit: Unit = .kib
        var summarize = false
        var allFiles = false
        var maxDepth: Int? = nil
        var paths: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { paths.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-s" || a == "--summarize" { summarize = true; i += 1; continue }
            if a == "-a" || a == "--all" { allFiles = true; i += 1; continue }
            if a == "-h" || a == "--human-readable" { unit = .human; i += 1; continue }
            if a == "-b" || a == "--bytes" { unit = .bytes; i += 1; continue }
            if a == "-k" { unit = .kib; i += 1; continue }
            if a == "-m" { unit = .mib; i += 1; continue }
            if a == "-d" || a == "--max-depth" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]) else {
                    Shell.bashCurrent.stderr("du: -d requires N\n"); return ExitStatus(2)
                }
                maxDepth = n; i += 2; continue
            }
            if a.hasPrefix("--max-depth=") {
                guard let n = Int(a.dropFirst("--max-depth=".count)) else {
                    Shell.bashCurrent.stderr("du: invalid --max-depth\n"); return ExitStatus(2)
                }
                maxDepth = n; i += 1; continue
            }
            if a.hasPrefix("-") && a != "-" && a.count > 1 {
                Shell.bashCurrent.stderr("du: unknown option: \(a)\n"); return ExitStatus(2)
            }
            paths.append(a); i += 1
        }
        if paths.isEmpty { paths = ["."] }

        var hadError = false
        for p in paths {
            let resolved = Shell.bashCurrent.resolvePath(p)
            do {
                let total = try await walk(displayPath: p, abs: resolved,
                                           depth: 0, unit: unit,
                                           maxDepth: summarize ? 0 : maxDepth,
                                           allFiles: allFiles, summarize: summarize)
                if summarize {
                    Shell.bashCurrent.stdout("\(formatSize(total, unit: unit))\t\(p)\n")
                }
            } catch {
                Shell.bashCurrent.stderr("du: \(p): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func walk(displayPath: String, abs: String, depth: Int,
                      unit: Unit, maxDepth: Int?, allFiles: Bool, summarize: Bool) async throws -> Int64 {
        try Task.checkCancellation()
        guard let meta = try await Shell.bashCurrent.fileSystem.metadata(abs) else {
            throw FileSystemError.notFound(abs)
        }
        if meta.kind != .directory {
            if allFiles && !summarize {
                Shell.bashCurrent.stdout("\(formatSize(meta.size, unit: unit))\t\(displayPath)\n")
            }
            return meta.size
        }
        var total: Int64 = 0
        let entries = (try? await Shell.bashCurrent.fileSystem.list(abs)) ?? []
        for name in entries.sorted() {
            let childAbs = (abs as NSString).appendingPathComponent(name)
            let childDisplay = displayPath == "." ? "./\(name)"
                : (displayPath as NSString).appendingPathComponent(name)
            total += try await walk(displayPath: childDisplay, abs: childAbs,
                                    depth: depth + 1, unit: unit,
                                    maxDepth: maxDepth, allFiles: allFiles,
                                    summarize: summarize)
        }
        if !summarize {
            let withinDepth = (maxDepth.map { depth <= $0 } ?? true)
            if withinDepth {
                Shell.bashCurrent.stdout("\(formatSize(total, unit: unit))\t\(displayPath)\n")
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
        let n = Double(bytes)
        let k = 1024.0
        if n < k { return "\(bytes)B" }
        if n < k * k {
            let v = n / k
            return v < 10 ? String(format: "%.1fK", v) : "\(Int(v.rounded()))K"
        }
        if n < k * k * k {
            let v = n / (k * k)
            return v < 10 ? String(format: "%.1fM", v) : "\(Int(v.rounded()))M"
        }
        let v = n / (k * k * k)
        return v < 10 ? String(format: "%.1fG", v) : "\(Int(v.rounded()))G"
    }
}
