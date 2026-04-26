import ArgumentParser
import BashInterpreter
import Foundation

/// `cat [OPTIONS] [FILE...]` — concatenate files (or stdin) to stdout.
///
/// Supported flags:
/// - `-n` / `--number` — number all output lines (1-based, right-aligned)
/// - `-b` / `--number-nonblank` — number non-blank lines only (overrides -n)
/// - `-s` / `--squeeze-blank` — collapse runs of blank lines into one
/// - `-E` / `--show-ends` — show `$` at end of each line
/// - `-T` / `--show-tabs` — show tabs as `^I`
/// - `-v` / `--show-nonprinting` — show control bytes as `^X` / `M-X`
/// - `-A` / `--show-all` — equivalent to `-vET`
/// - `-e` — equivalent to `-vE`
/// - `-t` — equivalent to `-vT`
///
/// Plain `cat` (no flags) streams binary chunks through unchanged.
/// Any flag that needs to inspect characters switches to line-mode
/// reading (UTF-8); pure-binary callers should pass no flags.
public struct CatCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "cat",
        abstract: "Concatenate files (or stdin) to stdout."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var number = false
        var numberNonblank = false
        var squeezeBlank = false
        var showEnds = false
        var showTabs = false
        var showNonprinting = false
        var files: [String] = []

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-" { files.append("-"); i += 1; continue }
            switch a {
            case "-n", "--number": number = true; i += 1; continue
            case "-b", "--number-nonblank": numberNonblank = true; i += 1; continue
            case "-s", "--squeeze-blank": squeezeBlank = true; i += 1; continue
            case "-E", "--show-ends": showEnds = true; i += 1; continue
            case "-T", "--show-tabs": showTabs = true; i += 1; continue
            case "-v", "--show-nonprinting": showNonprinting = true; i += 1; continue
            case "-A", "--show-all":
                showNonprinting = true; showEnds = true; showTabs = true
                i += 1; continue
            case "-e": showNonprinting = true; showEnds = true; i += 1; continue
            case "-t": showNonprinting = true; showTabs = true; i += 1; continue
            case "-u":
                // POSIX "unbuffered output" — we always flush per write.
                i += 1; continue
            default: break
            }
            if a.hasPrefix("--") {
                shell.stderr("cat: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            if a.hasPrefix("-") && a.count > 1 {
                for c in a.dropFirst() {
                    switch c {
                    case "n": number = true
                    case "b": numberNonblank = true
                    case "s": squeezeBlank = true
                    case "E": showEnds = true
                    case "T": showTabs = true
                    case "v": showNonprinting = true
                    case "A": showNonprinting = true; showEnds = true; showTabs = true
                    case "e": showNonprinting = true; showEnds = true
                    case "t": showNonprinting = true; showTabs = true
                    case "u": break
                    default:
                        shell.stderr("cat: unknown option: -\(c)\n")
                        return ExitStatus(2)
                    }
                }
                i += 1; continue
            }
            files.append(a); i += 1
        }

        let needsTransform = number || numberNonblank || squeezeBlank
            || showEnds || showTabs || showNonprinting
        let useFiles = files.isEmpty ? ["-"] : files

        // Fast path: no transform → stream raw bytes (binary-safe).
        if !needsTransform {
            return await streamRaw(useFiles, shell: shell)
        }

        // Line-mode transform path.
        var lineNumber = 0
        var prevWasBlank = false
        var hadError = false

        for path in useFiles {
            do {
                let source: InputSource
                if path == "-" { source = shell.stdin }
                else { source = try await shell.openInputPath(path) }
                for await line in source.lines {
                    let isBlank = line.isEmpty
                    if squeezeBlank && isBlank && prevWasBlank { continue }
                    prevWasBlank = isBlank
                    var prefix = ""
                    if numberNonblank {
                        if !isBlank {
                            lineNumber += 1
                            prefix = String(format: "%6d\t", lineNumber)
                        }
                    } else if number {
                        lineNumber += 1
                        prefix = String(format: "%6d\t", lineNumber)
                    }
                    var body = line
                    if showTabs { body = body.replacingOccurrences(of: "\t", with: "^I") }
                    if showNonprinting { body = Self.escapeNonprinting(body) }
                    let suffix = showEnds ? "$" : ""
                    shell.stdout(prefix + body + suffix + "\n")
                }
            } catch FileSystemError.notFound {
                shell.stderr("cat: \(path): No such file or directory\n")
                hadError = true
            } catch FileSystemError.isADirectory {
                shell.stderr("cat: \(path): Is a directory\n")
                hadError = true
            } catch {
                shell.stderr("cat: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func streamRaw(_ files: [String], shell: Shell) async -> ExitStatus {
        var hadError = false
        for path in files {
            if path == "-" {
                for await chunk in shell.stdin.bytes { shell.stdout(chunk) }
                continue
            }
            do {
                let source = try await shell.openInputPath(path)
                for await chunk in source.bytes { shell.stdout(chunk) }
            } catch FileSystemError.notFound {
                shell.stderr("cat: \(path): No such file or directory\n")
                hadError = true
            } catch FileSystemError.isADirectory {
                shell.stderr("cat: \(path): Is a directory\n")
                hadError = true
            } catch {
                shell.stderr("cat: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    /// Encode control bytes the way `cat -v` does:
    /// - 0x00–0x1F (except `\t` and `\n`) → `^X`
    /// - 0x7F → `^?`
    /// - 0x80+ → `M-` followed by recursive escape
    static func escapeNonprinting(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v == 0x09 || v == 0x0A {
                out.unicodeScalars.append(scalar)
            } else if v < 0x20 {
                out.append("^")
                out.unicodeScalars.append(Unicode.Scalar(v + 0x40)!)
            } else if v == 0x7F {
                out += "^?"
            } else if v < 0x7F {
                out.unicodeScalars.append(scalar)
            } else if v < 0xA0 {
                out += "M-^"
                out.unicodeScalars.append(Unicode.Scalar(v - 0x80 + 0x40)!)
            } else {
                out += "M-"
                out.unicodeScalars.append(Unicode.Scalar(v - 0x80)!)
            }
        }
        return out
    }
}
