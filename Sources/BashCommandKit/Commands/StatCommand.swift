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
/// `%u`/`%g` owner uid/gid (from file metadata — a virtualizing FS
/// maps it to the sandbox identity, so no host id leaks, while a real FS
/// keeps per-file ownership), `%U`/`%G` owner user/group name (the shell
/// identity's, since there's no passwd map), `%h` link count (always 1).
public struct StatCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "stat",
        abstract: "Display file metadata."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    // swiftlint:disable:next cyclomatic_complexity
    public mutating func execute() async throws -> ExitStatus {
        var format: String?
        var files: [String] = []
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count { files.append(rawArgv[index]); index += 1 }
                break
            }
            if arg == "-c" || arg == "--format" {
                guard index + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("stat: -c requires FORMAT\n"); return ExitStatus(2)
                }
                format = rawArgv[index + 1]; index += 2; continue
            }
            if arg.hasPrefix("--format=") {
                format = String(arg.dropFirst("--format=".count)); index += 1; continue
            }
            if arg.hasPrefix("-c") && arg.count > 2 {
                format = String(arg.dropFirst(2)); index += 1; continue
            }
            if arg.hasPrefix("-") && arg != "-" {
                Shell.bashCurrent.stderr("stat: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            files.append(arg); index += 1
        }

        var hadError = false
        for file in files {
            let resolved = Shell.bashCurrent.resolvePath(file)
            guard let meta = try? await Shell.bashCurrent.fileSystem.metadata(resolved) else {
                Shell.bashCurrent.stderr("stat: \(file): No such file or directory\n")
                hadError = true; continue
            }
            if let format {
                Shell.bashCurrent.stdout(formatString(format, name: file, meta: meta) + "\n")
            } else {
                Shell.bashCurrent.stdout(defaultStat(name: file, meta: meta))
            }
        }
        return hadError ? .failure : .success
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func formatString(_ fmt: String, name: String,
                              meta: FileMetadata) -> String {
        var out = ""
        // `%u`/`%g` come straight from file metadata — a virtualizing FS
        // (`MountedFileSystem`) already maps it to the sandbox identity,
        // so no host id leaks while a real FS keeps per-file ownership.
        // `%U`/`%G` render the shell identity's names (no passwd map to
        // resolve arbitrary uids).
        let host = Shell.bashCurrent.hostInfo
        let chars = Array(fmt)
        var index = 0
        while index < chars.count {
            if chars[index] == "%", index + 1 < chars.count {
                let char = chars[index + 1]
                switch char {
                case "n": out += name
                case "s": out += String(meta.size)
                case "y": out += FsTools.iso8601(meta.modifiedAt)
                case "F": out += FsTools.typeWord(meta.kind)
                case "a": out += String(meta.mode, radix: 8)
                case "A": out += FsTools.symbolicMode(kind: meta.kind, mode: meta.mode)
                case "N":
                    if meta.kind == .symlink, let target = meta.symlinkTarget {
                        out += "'\(name)' -> '\(target)'"
                    } else {
                        out += "'\(name)'"
                    }
                case "u": out += String(meta.uid)
                case "g": out += String(meta.gid)
                case "U": out += host.userName
                case "G": out += host.groupName
                case "h": out += String(meta.linkCount)
                case "%": out += "%"
                default: out.append(char)
                }
                index += 2
            } else if chars[index] == "\\", index + 1 < chars.count {
                let next = chars[index + 1]
                switch next {
                case "n": out += "\n"
                case "t": out += "\t"
                default: out.append(next)
                }
                index += 2
            } else {
                out.append(chars[index]); index += 1
            }
        }
        return out
    }

    private func defaultStat(name: String, meta: FileMetadata) -> String {
        var summary = ""
        summary += "  File: \(name)\n"
        summary += "  Size: \(meta.size)\t\(FsTools.typeWord(meta.kind))\n"
        let modeStr = String(format: "%04o", meta.mode)
        let symbolicMode = FsTools.symbolicMode(kind: meta.kind, mode: meta.mode)
        // From file metadata — virtualized by the FS in a sandbox, the
        // real owner on a real FS (see formatString).
        let uidStr = String(format: "%5d", meta.uid)
        let gidStr = String(format: "%5d", meta.gid)
        summary += "Access: (\(modeStr)/\(symbolicMode))  "
        summary += "Uid: (\(uidStr))   Gid: (\(gidStr))\n"
        summary += "Access: \(FsTools.iso8601(meta.accessedAt))\n"
        summary += "Modify: \(FsTools.iso8601(meta.modifiedAt))\n"
        summary += "Change: \(FsTools.iso8601(meta.createdAt))\n"
        return summary
    }
}
