import ArgumentParser
import BashInterpreter
import Foundation

/// `patch [OPTIONS] [FILE [PATCHFILE]]` — apply a unified diff.
///
/// Reads the patch from PATCHFILE, `-i FILE`, or stdin. The target
/// file path is taken from the patch header (`+++ b/path`) or from
/// the first argument; `-p N` strips N leading components, mirroring
/// GNU `patch`.
///
/// - `-p N` — strip N leading components from header paths (default 1)
/// - `-R` / `--reverse` — apply the patch in reverse
/// - `-i FILE` / `--input=FILE` — read the patch from FILE
/// - `-d DIR` — change to DIR before applying
/// - `--dry-run` — don't write changes
///
/// Supported: standard unified-diff hunk format. Skipped: ed-style
/// patches, context-style (rare today), fuzzy matching.
public struct PatchCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "patch",
        abstract: "Apply a unified-diff patch."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then [FILE [PATCHFILE]]")
    public var rawArgv: [String] = []

    public init() {}

    // GNU-`patch` option parsing has 10+ flag forms; one branch per spec
    // case keeps the table inline.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        var stripCount = 1
        var reverse = false
        var inputFile: String?
        var changeDir: String?
        var dryRun = false
        var positionals: [String] = []
        var idx = 0
        while idx < rawArgv.count {
            let arg = rawArgv[idx]
            if arg == "--" {
                idx += 1
                while idx < rawArgv.count { positionals.append(rawArgv[idx]); idx += 1 }
                break
            }
            if arg == "-p" || arg == "--strip" {
                guard idx + 1 < rawArgv.count, let count = Int(rawArgv[idx + 1]) else {
                    Shell.bashCurrent.stderr("patch: -p requires N\n"); return ExitStatus(2)
                }
                stripCount = count; idx += 2; continue
            }
            if arg.hasPrefix("-p") && arg.count > 2, let count = Int(arg.dropFirst(2)) {
                stripCount = count; idx += 1; continue
            }
            if arg.hasPrefix("--strip=") {
                guard let count = Int(arg.dropFirst("--strip=".count)) else {
                    Shell.bashCurrent.stderr("patch: invalid --strip\n"); return ExitStatus(2)
                }
                stripCount = count; idx += 1; continue
            }
            if arg == "-R" || arg == "--reverse" { reverse = true; idx += 1; continue }
            if arg == "-i" || arg == "--input" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("patch: -i requires FILE\n"); return ExitStatus(2)
                }
                inputFile = rawArgv[idx + 1]; idx += 2; continue
            }
            if arg.hasPrefix("--input=") {
                inputFile = String(arg.dropFirst("--input=".count)); idx += 1; continue
            }
            if arg == "-d" || arg == "--directory" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("patch: -d requires DIR\n"); return ExitStatus(2)
                }
                changeDir = rawArgv[idx + 1]; idx += 2; continue
            }
            if arg == "--dry-run" { dryRun = true; idx += 1; continue }
            if arg.hasPrefix("-") && arg.count > 1 && arg != "-" {
                Shell.bashCurrent.stderr("patch: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            positionals.append(arg); idx += 1
        }

        // Resolve sources.
        let patchText: String
        do {
            if let path = inputFile {
                let data = try await Shell.bashCurrent.readDataAtPath(path)
                // Patch text may legitimately be partial UTF-8 (binary patches).
                // swiftlint:disable:next optional_data_string_conversion
                patchText = String(decoding: data, as: UTF8.self)
            } else if positionals.count >= 2 {
                let data = try await Shell.bashCurrent.readDataAtPath(positionals[1])
                // Patch text may legitimately be partial UTF-8 (binary patches).
                // swiftlint:disable:next optional_data_string_conversion
                patchText = String(decoding: data, as: UTF8.self)
            } else {
                patchText = await Shell.bashCurrent.stdin.readAllString()
            }
        } catch {
            Shell.bashCurrent.stderr("patch: \(error)\n")
            return .failure
        }

        let cwd = changeDir.map { Shell.bashCurrent.resolvePath($0) }
            ?? Shell.bashCurrent.environment.workingDirectory
        let hunks = parsePatch(patchText)
        if hunks.isEmpty {
            Shell.bashCurrent.stderr("patch: no hunks found\n")
            return .failure
        }

        // Group hunks by target file.
        var byFile: [(String, [Hunk])] = []
        for hunk in hunks {
            let target: String
            if positionals.count >= 1, !positionals[0].hasPrefix("-") {
                target = positionals[0]
            } else {
                target = strip(hunk.targetHeader, levels: stripCount)
            }
            if let existing = byFile.firstIndex(where: { $0.0 == target }) {
                byFile[existing].1.append(hunk)
            } else {
                byFile.append((target, [hunk]))
            }
        }

        var hadError = false
        for (relPath, fileHunks) in byFile {
            let absPath = (relPath as NSString).isAbsolutePath
                ? relPath : (cwd as NSString).appendingPathComponent(relPath)
            let original: [String]
            do {
                let data = try await Shell.bashCurrent.readDataAtPath(absPath)
                // Patched files may legitimately be partial UTF-8.
                // swiftlint:disable:next optional_data_string_conversion
                original = SortCommand.splitLines(String(decoding: data, as: UTF8.self))
            } catch {
                Shell.bashCurrent.stderr("patch: \(relPath): \(error)\n")
                hadError = true; continue
            }
            do {
                let updated = try apply(hunks: fileHunks, to: original, reverse: reverse)
                if !dryRun {
                    let out = updated.joined(separator: "\n") + "\n"
                    try await Shell.bashCurrent.writeData(Data(out.utf8),
                                                          toPath: absPath, append: false)
                }
                Shell.bashCurrent.stdout("patching file \(relPath)\n")
            } catch let err as PatchError {
                Shell.bashCurrent.stderr("patch: \(relPath): \(err.message)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    // MARK: parsing

    struct Hunk {
        let oldStart: Int        // 1-based
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let lines: [String]      // includes the leading +/-/space
        let sourceHeader: String // `--- a/path`
        let targetHeader: String // `+++ b/path`
    }

    struct PatchError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func parsePatch(_ text: String) -> [Hunk] {
        var hunks: [Hunk] = []
        let lines = text.components(separatedBy: "\n")
        var idx = 0
        var srcHeader = ""
        var tgtHeader = ""
        while idx < lines.count {
            let line = lines[idx]
            if line.hasPrefix("--- ") {
                srcHeader = String(line.dropFirst(4)).split(separator: "\t")
                    .first.map(String.init) ?? ""
                idx += 1; continue
            }
            if line.hasPrefix("+++ ") {
                tgtHeader = String(line.dropFirst(4)).split(separator: "\t")
                    .first.map(String.init) ?? ""
                idx += 1; continue
            }
            if line.hasPrefix("@@") {
                guard let header = parseHunkHeader(line) else {
                    idx += 1; continue
                }
                idx += 1
                var body: [String] = []
                while idx < lines.count {
                    let bodyLine = lines[idx]
                    if bodyLine.hasPrefix("@@")
                        || bodyLine.hasPrefix("--- ")
                        || bodyLine.hasPrefix("+++ ") {
                        break
                    }
                    if bodyLine.isEmpty
                        && body.count >= header.oldStart + header.newStart {
                        break
                    }
                    body.append(bodyLine)
                    idx += 1
                }
                hunks.append(Hunk(oldStart: header.oldStart, oldCount: header.oldCount,
                                  newStart: header.newStart, newCount: header.newCount,
                                  lines: body,
                                  sourceHeader: srcHeader, targetHeader: tgtHeader))
                continue
            }
            idx += 1
        }
        return hunks
    }

    private struct HunkHeader {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
    }

    /// Parse `@@ -A,B +C,D @@ optional comment` — counts default to 1.
    private func parseHunkHeader(_ line: String) -> HunkHeader? {
        // Match by regex.
        let pattern = #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsstr = line as NSString
        guard let match = regex.firstMatch(
            in: line, range: NSRange(location: 0, length: nsstr.length)) else {
            return nil
        }
        func capture(_ index: Int) -> Int? {
            let range = match.range(at: index)
            if range.location == NSNotFound { return nil }
            return Int(nsstr.substring(with: range))
        }
        return HunkHeader(oldStart: capture(1) ?? 0,
                          oldCount: capture(2) ?? 1,
                          newStart: capture(3) ?? 0,
                          newCount: capture(4) ?? 1)
    }

    private func strip(_ path: String, levels: Int) -> String {
        var parts = path.components(separatedBy: "/")
        for _ in 0..<levels where !parts.isEmpty {
            parts.removeFirst()
        }
        return parts.joined(separator: "/")
    }

    // Hunk-application helpers live in `PatchCommand+Apply.swift`.
}
