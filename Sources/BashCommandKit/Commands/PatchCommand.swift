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

    public mutating func execute() async throws -> ExitStatus {
        var stripCount = 1
        var reverse = false
        var inputFile: String? = nil
        var changeDir: String? = nil
        var dryRun = false
        var positionals: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { positionals.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-p" || a == "--strip" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]) else {
                    Shell.bashCurrent.stderr("patch: -p requires N\n"); return ExitStatus(2)
                }
                stripCount = n; i += 2; continue
            }
            if a.hasPrefix("-p") && a.count > 2, let n = Int(a.dropFirst(2)) {
                stripCount = n; i += 1; continue
            }
            if a.hasPrefix("--strip=") {
                guard let n = Int(a.dropFirst("--strip=".count)) else {
                    Shell.bashCurrent.stderr("patch: invalid --strip\n"); return ExitStatus(2)
                }
                stripCount = n; i += 1; continue
            }
            if a == "-R" || a == "--reverse" { reverse = true; i += 1; continue }
            if a == "-i" || a == "--input" {
                guard i + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("patch: -i requires FILE\n"); return ExitStatus(2)
                }
                inputFile = rawArgv[i + 1]; i += 2; continue
            }
            if a.hasPrefix("--input=") {
                inputFile = String(a.dropFirst("--input=".count)); i += 1; continue
            }
            if a == "-d" || a == "--directory" {
                guard i + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("patch: -d requires DIR\n"); return ExitStatus(2)
                }
                changeDir = rawArgv[i + 1]; i += 2; continue
            }
            if a == "--dry-run" { dryRun = true; i += 1; continue }
            if a.hasPrefix("-") && a.count > 1 && a != "-" {
                Shell.bashCurrent.stderr("patch: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            positionals.append(a); i += 1
        }

        // Resolve sources.
        let patchText: String
        do {
            if let p = inputFile {
                let data = try await Shell.bashCurrent.readDataAtPath(p)
                patchText = String(decoding: data, as: UTF8.self)
            } else if positionals.count >= 2 {
                let data = try await Shell.bashCurrent.readDataAtPath(positionals[1])
                patchText = String(decoding: data, as: UTF8.self)
            } else {
                patchText = await Shell.bashCurrent.stdin.readAllString()
            }
        } catch {
            Shell.bashCurrent.stderr("patch: \(error)\n")
            return .failure
        }

        let cwd = changeDir.map { Shell.bashCurrent.resolvePath($0) } ?? Shell.bashCurrent.environment.workingDirectory
        let hunks = parsePatch(patchText)
        if hunks.isEmpty {
            Shell.bashCurrent.stderr("patch: no hunks found\n")
            return .failure
        }

        // Group hunks by target file.
        var byFile: [(String, [Hunk])] = []
        for h in hunks {
            let target: String
            if positionals.count >= 1, !positionals[0].hasPrefix("-") {
                target = positionals[0]
            } else {
                target = strip(h.targetHeader, levels: stripCount)
            }
            if let i = byFile.firstIndex(where: { $0.0 == target }) {
                byFile[i].1.append(h)
            } else {
                byFile.append((target, [h]))
            }
        }

        var hadError = false
        for (relPath, fileHunks) in byFile {
            let absPath = (relPath as NSString).isAbsolutePath
                ? relPath : (cwd as NSString).appendingPathComponent(relPath)
            let original: [String]
            do {
                let data = try await Shell.bashCurrent.readDataAtPath(absPath)
                original = SortCommand.splitLines(String(decoding: data, as: UTF8.self))
            } catch {
                Shell.bashCurrent.stderr("patch: \(relPath): \(error)\n")
                hadError = true; continue
            }
            do {
                let updated = try apply(hunks: fileHunks, to: original, reverse: reverse)
                if !dryRun {
                    let out = updated.joined(separator: "\n") + "\n"
                    try await Shell.bashCurrent.writeData(Data(out.utf8), toPath: absPath, append: false)
                }
                Shell.bashCurrent.stdout("patching file \(relPath)\n")
            } catch let e as PatchError {
                Shell.bashCurrent.stderr("patch: \(relPath): \(e.message)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    // MARK: parsing

    private struct Hunk {
        let oldStart: Int        // 1-based
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let lines: [String]      // includes the leading +/-/space
        let sourceHeader: String // `--- a/path`
        let targetHeader: String // `+++ b/path`
    }

    private struct PatchError: Error {
        let message: String
        init(_ m: String) { self.message = m }
    }

    private func parsePatch(_ text: String) -> [Hunk] {
        var hunks: [Hunk] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var srcHeader = ""
        var tgtHeader = ""
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("--- ") {
                srcHeader = String(line.dropFirst(4)).split(separator: "\t").first.map(String.init) ?? ""
                i += 1; continue
            }
            if line.hasPrefix("+++ ") {
                tgtHeader = String(line.dropFirst(4)).split(separator: "\t").first.map(String.init) ?? ""
                i += 1; continue
            }
            if line.hasPrefix("@@") {
                guard let header = parseHunkHeader(line) else {
                    i += 1; continue
                }
                i += 1
                var body: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.hasPrefix("@@") || l.hasPrefix("--- ") || l.hasPrefix("+++ ") { break }
                    if l.isEmpty && body.count >= header.0 + header.2 { break }
                    body.append(l)
                    i += 1
                }
                hunks.append(Hunk(oldStart: header.0, oldCount: header.1,
                                  newStart: header.2, newCount: header.3,
                                  lines: body,
                                  sourceHeader: srcHeader, targetHeader: tgtHeader))
                continue
            }
            i += 1
        }
        return hunks
    }

    /// Parse `@@ -A,B +C,D @@ optional comment` — counts default to 1.
    private func parseHunkHeader(_ line: String) -> (Int, Int, Int, Int)? {
        // Match by regex.
        let pattern = #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsstr = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: nsstr.length)) else {
            return nil
        }
        func capture(_ idx: Int) -> Int? {
            let r = m.range(at: idx)
            if r.location == NSNotFound { return nil }
            return Int(nsstr.substring(with: r))
        }
        let oldStart = capture(1) ?? 0
        let oldCount = capture(2) ?? 1
        let newStart = capture(3) ?? 0
        let newCount = capture(4) ?? 1
        return (oldStart, oldCount, newStart, newCount)
    }

    private func strip(_ path: String, levels: Int) -> String {
        var parts = path.components(separatedBy: "/")
        for _ in 0..<levels {
            if !parts.isEmpty { parts.removeFirst() }
        }
        return parts.joined(separator: "/")
    }

    // MARK: applying

    private func apply(hunks: [Hunk], to original: [String], reverse: Bool) throws -> [String] {
        // Apply hunks in source order, building output with offset
        // tracking so subsequent hunk indices stay correct.
        var out = original
        // Offset between original index and output index (for adjusting
        // later hunk start positions after earlier hunks change line
        // counts).
        var offset = 0
        for hunk in hunks {
            let h = reverse ? reversedHunk(hunk) : hunk
            let idx = h.oldStart - 1 + offset
            // Sanity-check: the lines we expect to remove or pass
            // through should match the file at this position.
            var contextChecked = 0
            var consumed = 0
            var produced: [String] = []
            for line in h.lines {
                guard let kind = line.first else { continue }
                let body = String(line.dropFirst())
                switch kind {
                case " ":
                    // Context: must match.
                    guard idx + contextChecked < out.count,
                          out[idx + contextChecked] == body else {
                        throw PatchError("hunk failed at line \(idx + contextChecked + 1)")
                    }
                    produced.append(body)
                    contextChecked += 1
                    consumed += 1
                case "-":
                    // Must match original.
                    guard idx + contextChecked < out.count,
                          out[idx + contextChecked] == body else {
                        throw PatchError("hunk failed at line \(idx + contextChecked + 1)")
                    }
                    contextChecked += 1
                    consumed += 1
                case "+":
                    produced.append(body)
                default:
                    // Skip pseudo-lines like "\ No newline at end of file".
                    continue
                }
            }
            // Replace the range [idx ..< idx + consumed] with produced.
            let endIdx = min(idx + consumed, out.count)
            out.replaceSubrange(idx..<endIdx, with: produced)
            offset += produced.count - consumed
        }
        return out
    }

    private func reversedHunk(_ h: Hunk) -> Hunk {
        var swapped: [String] = []
        for line in h.lines {
            guard let first = line.first else { continue }
            let body = line.dropFirst()
            switch first {
            case "+": swapped.append("-" + body)
            case "-": swapped.append("+" + body)
            default:  swapped.append(line)
            }
        }
        return Hunk(oldStart: h.newStart, oldCount: h.newCount,
                    newStart: h.oldStart, newCount: h.oldCount,
                    lines: swapped,
                    sourceHeader: h.targetHeader, targetHeader: h.sourceHeader)
    }
}
