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

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
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
                    shell.stderr("stat: -c requires FORMAT\n"); return ExitStatus(2)
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
                shell.stderr("stat: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            files.append(a); i += 1
        }

        var hadError = false
        for f in files {
            let resolved = shell.resolvePath(f)
            guard let meta = try? await shell.fileSystem.metadata(resolved) else {
                shell.stderr("stat: \(f): No such file or directory\n")
                hadError = true; continue
            }
            let mode = (try? FsTools.statMode(resolved)) ?? 0o644
            if let format {
                shell.stdout(formatString(format, name: f, meta: meta, mode: mode) + "\n")
            } else {
                shell.stdout(defaultStat(name: f, meta: meta, mode: mode))
            }
        }
        return hadError ? .failure : .success
    }

    private func formatString(_ fmt: String, name: String,
                              meta: FileMetadata, mode: UInt16) -> String {
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
                case "a": out += String(mode, radix: 8)
                case "A": out += FsTools.symbolicMode(kind: meta.kind, mode: mode)
                case "N":
                    if meta.kind == .symlink, let t = meta.symlinkTarget {
                        out += "'\(name)' -> '\(t)'"
                    } else {
                        out += "'\(name)'"
                    }
                case "U": out += "user"
                case "G": out += "group"
                case "h": out += "1"
                case "%": out += "%"
                case "n" where false: break
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

    private func defaultStat(name: String, meta: FileMetadata, mode: UInt16) -> String {
        var s = ""
        s += "  File: \(name)\n"
        s += "  Size: \(meta.size)\t\(FsTools.typeWord(meta.kind))\n"
        s += "Access: (\(String(format: "%04o", mode))/\(FsTools.symbolicMode(kind: meta.kind, mode: mode)))  Uid: (   0/    user)   Gid: (   0/   group)\n"
        s += "Modify: \(FsTools.iso8601(meta.modifiedAt))\n"
        return s
    }
}

/// `readlink FILE...` — print the target of each symbolic link.
public struct ReadlinkCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "readlink",
        abstract: "Print the target of a symbolic link."
    )

    @Flag(name: [.customShort("f"), .customLong("canonicalize")],
          help: "Canonicalize: each component must exist except possibly the last.")
    public var canonicalize: Bool = false

    @Argument(help: "Symlink files to inspect.")
    public var files: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        guard !files.isEmpty else {
            shell.stderr("readlink: missing operand\n")
            return ExitStatus(2)
        }
        var hadError = false
        for f in files {
            let resolved = shell.resolvePath(f)
            if canonicalize {
                let canonical = (try? FsTools.realpath(resolved)) ?? resolved
                shell.stdout(canonical + "\n")
                continue
            }
            guard let meta = try? await shell.fileSystem.metadata(resolved) else {
                shell.stderr("readlink: \(f): No such file or directory\n")
                hadError = true; continue
            }
            // Our metadata follows symlinks already, so symlinkTarget
            // is `nil` for resolved targets. Use lstat directly via
            // POSIX to read the link.
            if let target = try? FsTools.readlink(resolved) {
                shell.stdout(target + "\n")
            } else if let target = meta.symlinkTarget {
                shell.stdout(target + "\n")
            } else {
                shell.stderr("readlink: \(f): Not a symlink\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}

/// `ln [-s] [-f] TARGET LINK_NAME` / `ln [-s] [-f] TARGET... DIRECTORY`
/// — create hard or symbolic links.
public struct LnCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ln",
        abstract: "Create links between files."
    )

    @Flag(name: [.customShort("s"), .customLong("symbolic")],
          help: "Create symbolic links instead of hard links.")
    public var symbolic: Bool = false

    @Flag(name: [.customShort("f"), .customLong("force")],
          help: "Overwrite an existing destination.")
    public var force: Bool = false

    @Argument(help: "TARGET... [LINK_OR_DIRECTORY]")
    public var operands: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        guard operands.count >= 2 else {
            shell.stderr("ln: missing operand\n")
            return ExitStatus(2)
        }
        let last = operands.last!
        let lastResolved = shell.resolvePath(last)
        let isDir = (try? await shell.fileSystem.metadata(lastResolved))?.kind == .directory
        let targets: [String]
        var destination: String
        if isDir && operands.count > 2 {
            targets = Array(operands.dropLast())
            destination = lastResolved
        } else if operands.count == 2 {
            targets = [operands[0]]
            destination = lastResolved
        } else {
            shell.stderr("ln: target '\(last)' is not a directory\n")
            return ExitStatus(1)
        }
        var hadError = false
        for target in targets {
            let dest: String
            if isDir {
                let base = (target as NSString).lastPathComponent
                dest = (destination as NSString).appendingPathComponent(base)
            } else {
                dest = destination
            }
            do {
                if force, let _ = try? await shell.fileSystem.metadata(dest) {
                    try? await shell.fileSystem.remove(dest, recursive: false)
                }
                if symbolic {
                    try FsTools.symlink(target: target, at: dest)
                } else {
                    try FsTools.hardlink(target: shell.resolvePath(target), at: dest)
                }
            } catch {
                shell.stderr("ln: \(dest): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}

/// `chmod MODE FILE...` — change file permission bits. MODE is octal
/// only (we don't yet parse symbolic modes like `u+x`).
public struct ChmodCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "chmod",
        abstract: "Change file permission bits."
    )

    @Flag(name: [.customShort("R"), .customLong("recursive")],
          help: "Operate on directories recursively.")
    public var recursive: Bool = false

    @Argument(help: "MODE FILE...")
    public var operands: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        guard operands.count >= 2 else {
            shell.stderr("chmod: missing operand\n")
            return ExitStatus(2)
        }
        let modeStr = operands[0]
        guard let mode = UInt16(modeStr, radix: 8) else {
            shell.stderr("chmod: invalid mode: \(modeStr)\n")
            return ExitStatus(2)
        }
        var hadError = false
        for f in operands.dropFirst() {
            let resolved = shell.resolvePath(f)
            do {
                try FsTools.chmod(resolved, mode: mode)
                if recursive {
                    try await applyRecursive(resolved, mode: mode, shell: shell)
                }
            } catch {
                shell.stderr("chmod: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func applyRecursive(_ path: String, mode: UInt16, shell: Shell) async throws {
        guard let meta = try? await shell.fileSystem.metadata(path),
              meta.kind == .directory else { return }
        let entries = (try? await shell.fileSystem.list(path)) ?? []
        for name in entries {
            let child = (path as NSString).appendingPathComponent(name)
            try? FsTools.chmod(child, mode: mode)
            try await applyRecursive(child, mode: mode, shell: shell)
        }
    }
}

/// Static POSIX wrappers shared by stat/readlink/ln/chmod.
enum FsTools {
    static func statMode(_ path: String) throws -> UInt16 {
        var st = stat()
        let r = path.withCString { lstat($0, &st) }
        guard r == 0 else { throw FileSystemError.notFound(path) }
        return UInt16(st.st_mode & 0o7777)
    }

    static func readlink(_ path: String) throws -> String {
        var buf = [Int8](repeating: 0, count: 4096)
        let n = path.withCString { p in
            buf.withUnsafeMutableBufferPointer { bp in
                Darwin.readlink(p, bp.baseAddress, bp.count)
            }
        }
        guard n > 0 else { throw FileSystemError.notFound(path) }
        let bytes = Array(buf.prefix(Int(n))).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func realpath(_ path: String) throws -> String {
        var buf = [Int8](repeating: 0, count: 4096)
        let r = path.withCString { p in
            buf.withUnsafeMutableBufferPointer { bp in
                Darwin.realpath(p, bp.baseAddress)
            }
        }
        guard r != nil else { throw FileSystemError.notFound(path) }
        return String(cString: r!)
    }

    static func symlink(target: String, at path: String) throws {
        let r = target.withCString { tp in
            path.withCString { pp in
                Darwin.symlink(tp, pp)
            }
        }
        guard r == 0 else { throw FileSystemError.io("symlink failed") }
    }

    static func hardlink(target: String, at path: String) throws {
        let r = target.withCString { tp in
            path.withCString { pp in
                Darwin.link(tp, pp)
            }
        }
        guard r == 0 else { throw FileSystemError.io("link failed") }
    }

    static func chmod(_ path: String, mode: UInt16) throws {
        let r = path.withCString { Darwin.chmod($0, mode_t(mode)) }
        guard r == 0 else { throw FileSystemError.io("chmod failed") }
    }

    static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    static func typeWord(_ kind: FileMetadata.Kind) -> String {
        switch kind {
        case .directory: return "directory"
        case .symlink: return "symbolic link"
        case .other: return "special file"
        case .file: return "regular file"
        }
    }

    static func symbolicMode(kind: FileMetadata.Kind, mode: UInt16) -> String {
        let kindCh: Character
        switch kind {
        case .directory: kindCh = "d"
        case .symlink: kindCh = "l"
        case .other: kindCh = "?"
        case .file: kindCh = "-"
        }
        let triplet: (UInt16) -> String = { bits in
            let r = (bits & 0b100) != 0 ? "r" : "-"
            let w = (bits & 0b010) != 0 ? "w" : "-"
            let x = (bits & 0b001) != 0 ? "x" : "-"
            return r + w + x
        }
        let owner = triplet((mode >> 6) & 0o7)
        let group = triplet((mode >> 3) & 0o7)
        let world = triplet(mode & 0o7)
        return String(kindCh) + owner + group + world
    }
}
