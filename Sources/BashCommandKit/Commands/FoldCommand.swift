import ArgumentParser
import BashInterpreter
import Foundation

/// `fold [-w WIDTH] [-s] [-b] [FILE...]` — wrap lines.
///
/// - `-w N` / `--width=N` — wrap at N columns (default 80)
/// - `-s` / `--spaces` — break at spaces only
/// - `-b` / `--bytes` — count bytes instead of columns
public struct FoldCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "fold",
        abstract: "Wrap lines."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var width = 80
        var atSpaces = false
        var byBytes = false
        var files: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-s" || a == "--spaces" { atSpaces = true; i += 1; continue }
            if a == "-b" || a == "--bytes" { byBytes = true; i += 1; continue }
            if a == "-w" || a == "--width" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]), n > 0 else {
                    Shell.current.stderr("fold: -w requires WIDTH\n"); return ExitStatus(2)
                }
                width = n; i += 2; continue
            }
            if a.hasPrefix("--width=") {
                guard let n = Int(a.dropFirst("--width=".count)), n > 0 else {
                    Shell.current.stderr("fold: invalid --width\n"); return ExitStatus(2)
                }
                width = n; i += 1; continue
            }
            if a.hasPrefix("-") && a.count > 1 && a != "-" {
                if let n = Int(a.dropFirst()) { width = n; i += 1; continue }
                Shell.current.stderr("fold: unknown option: \(a)\n"); return ExitStatus(2)
            }
            files.append(a); i += 1
        }

        let inputs = files.isEmpty ? ["-"] : files
        var hadError = false
        for f in inputs {
            try Task.checkCancellation()
            do {
                let text: String
                if f == "-" { text = await Shell.current.stdin.readAllString() }
                else {
                    let data = try await Shell.current.readDataAtPath(f)
                    text = String(decoding: data, as: UTF8.self)
                }
                Shell.current.stdout(FoldCommand.fold(text, width: width, atSpaces: atSpaces, byBytes: byBytes))
            } catch {
                Shell.current.stderr("fold: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    static func fold(_ text: String, width: Int, atSpaces: Bool, byBytes: Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        let inputEndsNL = !lines.isEmpty && lines.last == ""
        if inputEndsNL { lines.removeLast() }
        var out = ""
        for line in lines {
            var s = line
            while !s.isEmpty {
                let units = byBytes ? s.utf8.count : s.count
                if units <= width {
                    out += s + "\n"; break
                }
                var splitAt = width
                if atSpaces {
                    // Find last space at or before `width`.
                    let chars = Array(s)
                    var found: Int? = nil
                    for j in (0..<min(width, chars.count)).reversed() {
                        if chars[j] == " " { found = j + 1; break }
                    }
                    if let f = found, f > 0 { splitAt = f }
                }
                let chars = Array(s)
                let head = String(chars[..<splitAt])
                let tail = String(chars[splitAt...])
                out += head + "\n"
                s = tail
            }
        }
        if !inputEndsNL && out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}
