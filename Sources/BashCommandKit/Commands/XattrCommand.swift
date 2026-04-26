import ArgumentParser
import BashInterpreter
import Foundation

/// `xattr [-l] [-p ATTR] [-w ATTR VALUE] [-d ATTR] [-c] [-r] FILE...`
/// — list / read / write / delete extended attributes.
///
/// macOS-style invocation. Default (no flags) lists attribute names.
///
/// - `-l` — list attribute names AND their values
/// - `-p ATTR FILE...` — print the value of one attribute
/// - `-w ATTR VALUE FILE...` — write a value
/// - `-d ATTR FILE...` — delete one attribute
/// - `-c` — clear (delete all attributes)
/// - `-r` — recurse into directories
public struct XattrCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "xattr",
        abstract: "Display and manipulate extended attributes."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then attribute and FILE arguments.")
    public var rawArgv: [String] = []

    public init() {}

    private enum Mode { case list, listLong, print, write, delete, clear }

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var mode: Mode = .list
        var recursive = false
        var args: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { args.append(rawArgv[i]); i += 1 }
                break
            }
            switch a {
            case "-l": mode = .listLong; i += 1; continue
            case "-p": mode = .print; i += 1; continue
            case "-w": mode = .write; i += 1; continue
            case "-d": mode = .delete; i += 1; continue
            case "-c": mode = .clear; i += 1; continue
            case "-r": recursive = true; i += 1; continue
            default: break
            }
            // Combined short flags like -lr.
            if a.hasPrefix("-") && a.count > 1 && a != "-" {
                for c in a.dropFirst() {
                    switch c {
                    case "l": mode = .listLong
                    case "p": mode = .print
                    case "w": mode = .write
                    case "d": mode = .delete
                    case "c": mode = .clear
                    case "r": recursive = true
                    default:
                        shell.stderr("xattr: unknown option: -\(c)\n")
                        return ExitStatus(2)
                    }
                }
                i += 1; continue
            }
            args.append(a); i += 1
        }

        let attrName: String?
        let attrValue: String?
        let files: [String]
        switch mode {
        case .write:
            guard args.count >= 3 else {
                shell.stderr("xattr: -w requires ATTR VALUE FILE\n")
                return ExitStatus(2)
            }
            attrName = args[0]; attrValue = args[1]
            files = Array(args.dropFirst(2))
        case .print, .delete:
            guard args.count >= 2 else {
                shell.stderr("xattr: option requires ATTR FILE\n")
                return ExitStatus(2)
            }
            attrName = args[0]; attrValue = nil
            files = Array(args.dropFirst())
        default:
            attrName = nil; attrValue = nil
            files = args
        }

        guard !files.isEmpty else {
            shell.stderr("xattr: missing FILE\n")
            return ExitStatus(2)
        }

        var hadError = false
        for f in files {
            do {
                try await processPath(f, shell: shell, mode: mode,
                                      recursive: recursive,
                                      attrName: attrName, attrValue: attrValue,
                                      multiple: files.count > 1)
            } catch {
                shell.stderr("xattr: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func processPath(_ path: String, shell: Shell, mode: Mode,
                             recursive: Bool, attrName: String?, attrValue: String?,
                             multiple: Bool) async throws {
        let resolved = shell.resolvePath(path)
        let isDir = (try? await shell.fileSystem.metadata(resolved))?.kind == .directory

        try processOne(path, resolved: resolved, shell: shell, mode: mode,
                       attrName: attrName, attrValue: attrValue, multiple: multiple)

        if recursive, isDir {
            let entries = (try? await shell.fileSystem.list(resolved)) ?? []
            for name in entries.sorted() {
                let childPath = (path as NSString).appendingPathComponent(name)
                try await processPath(childPath, shell: shell, mode: mode,
                                      recursive: recursive,
                                      attrName: attrName, attrValue: attrValue,
                                      multiple: true)
            }
        }
    }

    private func processOne(_ path: String, resolved: String, shell: Shell,
                            mode: Mode, attrName: String?, attrValue: String?,
                            multiple: Bool) throws {
        let prefix = multiple ? "\(path): " : ""
        switch mode {
        case .list:
            let names = try Xattr.list(resolved)
            for n in names { shell.stdout(prefix + n + "\n") }
        case .listLong:
            let names = try Xattr.list(resolved)
            for n in names {
                let v = (try? Xattr.get(resolved, name: n)) ?? Data()
                let str = String(decoding: v, as: UTF8.self)
                shell.stdout("\(prefix)\(n): \(str)\n")
            }
        case .print:
            guard let n = attrName else { return }
            let v = try Xattr.get(resolved, name: n)
            shell.stdout(prefix + String(decoding: v, as: UTF8.self) + "\n")
        case .write:
            guard let n = attrName, let v = attrValue else { return }
            try Xattr.set(resolved, name: n, value: Data(v.utf8))
        case .delete:
            guard let n = attrName else { return }
            try Xattr.remove(resolved, name: n)
        case .clear:
            let names = try Xattr.list(resolved)
            for n in names {
                try? Xattr.remove(resolved, name: n)
            }
        }
    }
}

/// Thin wrappers around the POSIX-extended xattr family.
enum Xattr {

    static func list(_ path: String) throws -> [String] {
        let needed = path.withCString { listxattr($0, nil, 0, 0) }
        if needed < 0 { throw err("listxattr") }
        if needed == 0 { return [] }
        var buf = [Int8](repeating: 0, count: needed)
        let written = path.withCString { p in
            buf.withUnsafeMutableBufferPointer { bp in
                listxattr(p, bp.baseAddress, needed, 0)
            }
        }
        if written < 0 { throw err("listxattr") }
        var names: [String] = []
        var i = 0
        while i < written {
            let start = i
            while i < written, buf[i] != 0 { i += 1 }
            if i > start {
                let bytes = (start..<i).map { UInt8(bitPattern: buf[$0]) }
                names.append(String(decoding: bytes, as: UTF8.self))
            }
            i += 1
        }
        return names
    }

    static func get(_ path: String, name: String) throws -> Data {
        let needed = path.withCString { p in
            name.withCString { n in
                getxattr(p, n, nil, 0, 0, 0)
            }
        }
        if needed < 0 { throw err("getxattr") }
        if needed == 0 { return Data() }
        var buf = [UInt8](repeating: 0, count: needed)
        let written = path.withCString { p in
            name.withCString { n in
                buf.withUnsafeMutableBufferPointer { bp in
                    getxattr(p, n, bp.baseAddress, needed, 0, 0)
                }
            }
        }
        if written < 0 { throw err("getxattr") }
        return Data(buf.prefix(written))
    }

    static func set(_ path: String, name: String, value: Data) throws {
        let r = path.withCString { p in
            name.withCString { n in
                value.withUnsafeBytes { vb in
                    setxattr(p, n, vb.baseAddress, value.count, 0, 0)
                }
            }
        }
        if r < 0 { throw err("setxattr") }
    }

    static func remove(_ path: String, name: String) throws {
        let r = path.withCString { p in
            name.withCString { n in
                removexattr(p, n, 0)
            }
        }
        if r < 0 { throw err("removexattr") }
    }

    private static func err(_ op: String) -> NSError {
        let code = Int(errno)
        let msg = String(cString: strerror(errno))
        return NSError(domain: "xattr", code: code,
                       userInfo: [NSLocalizedDescriptionKey: "\(op): \(msg)"])
    }
}
