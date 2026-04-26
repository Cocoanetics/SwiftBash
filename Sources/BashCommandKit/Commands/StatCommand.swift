import ArgumentParser
import BashInterpreter
import Foundation

/// `stat [-c FORMAT] FILE...` — print file metadata.
///
/// Without `-c`, prints a multi-line summary similar to GNU stat.
/// With `-c FORMAT`, prints the format string with these tokens
/// substituted (subset of GNU): `%n` name, `%s` size, `%y` mtime
/// (ISO 8601 in UTC), `%F` file type word, `%a` permissions in
/// octal, `%A` symbolic mode, `%N` quoted name (with -> for symlinks),
/// `%U` owner user (always "user" since we don't carry uid mappings),
/// `%G` owner group ("group"), `%h` hard link count (always 1).
public struct StatCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "stat",
        abstract: "Display file metadata."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var format: String? = nil
        var files: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-c" || a == "--format" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("stat: -c requires FORMAT\n"); return ExitStatus(2)
                }
                format = rawArgv[i + 1]; i += 2; continue
            }
            if a.hasPrefix("--format=") {
                format = String(a.dropFirst("--format=".count)); i += 1; continue
            }
            if a.hasPrefix("-c") && a.count > 2 {
                format = String(a.dropFirst(2)); i += 1; continue
            }
            if a.hasPrefix("-") && a != "-" {
                Shell.current.stderr("stat: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            files.append(a); i += 1
        }

        var hadError = false
        for f in files {
            let resolved = Shell.current.resolvePath(f)
            guard let meta = try? await Shell.current.fileSystem.metadata(resolved) else {
                Shell.current.stderr("stat: \(f): No such file or directory\n")
                hadError = true; continue
            }
            if let format {
                Shell.current.stdout(formatString(format, name: f, meta: meta) + "\n")
            } else {
                Shell.current.stdout(defaultStat(name: f, meta: meta))
            }
        }
        return hadError ? .failure : .success
    }

    private func formatString(_ fmt: String, name: String,
                              meta: FileMetadata) -> String {
        var out = ""
        let chars = Array(fmt)
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 1 < chars.count {
                let c = chars[i + 1]
                switch c {
                case "n": out += name
                case "s": out += String(meta.size)
                case "y": out += FsTools.iso8601(meta.modifiedAt)
                case "F": out += FsTools.typeWord(meta.kind)
                case "a": out += String(meta.mode, radix: 8)
                case "A": out += FsTools.symbolicMode(kind: meta.kind, mode: meta.mode)
                case "N":
                    if meta.kind == .symlink, let t = meta.symlinkTarget {
                        out += "'\(name)' -> '\(t)'"
                    } else {
                        out += "'\(name)'"
                    }
                case "u": out += String(meta.uid)
                case "g": out += String(meta.gid)
                case "U": out += "user"
                case "G": out += "group"
                case "h": out += String(meta.linkCount)
                case "%": out += "%"
                default: out.append(c)
                }
                i += 2
            } else if chars[i] == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                switch n {
                case "n": out += "\n"
                case "t": out += "\t"
                default: out.append(n)
                }
                i += 2
            } else {
                out.append(chars[i]); i += 1
            }
        }
        return out
    }

    private func defaultStat(name: String, meta: FileMetadata) -> String {
        var s = ""
        s += "  File: \(name)\n"
        s += "  Size: \(meta.size)\t\(FsTools.typeWord(meta.kind))\n"
        s += "Access: (\(String(format: "%04o", meta.mode))/\(FsTools.symbolicMode(kind: meta.kind, mode: meta.mode)))  Uid: (\(String(format: "%5d", meta.uid)))   Gid: (\(String(format: "%5d", meta.gid)))\n"
        s += "Access: \(FsTools.iso8601(meta.accessedAt))\n"
        s += "Modify: \(FsTools.iso8601(meta.modifiedAt))\n"
        s += "Change: \(FsTools.iso8601(meta.createdAt))\n"
        return s
    }
}
