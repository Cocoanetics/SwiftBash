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

    public mutating func execute() async throws -> ExitStatus {
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
                        Shell.bashCurrent.stderr("xattr: unknown option: -\(c)\n")
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
                Shell.bashCurrent.stderr("xattr: -w requires ATTR VALUE FILE\n")
                return ExitStatus(2)
            }
            attrName = args[0]; attrValue = args[1]
            files = Array(args.dropFirst(2))
        case .print, .delete:
            guard args.count >= 2 else {
                Shell.bashCurrent.stderr("xattr: option requires ATTR FILE\n")
                return ExitStatus(2)
            }
            attrName = args[0]; attrValue = nil
            files = Array(args.dropFirst())
        default:
            attrName = nil; attrValue = nil
            files = args
        }

        guard !files.isEmpty else {
            Shell.bashCurrent.stderr("xattr: missing FILE\n")
            return ExitStatus(2)
        }

        var hadError = false
        for f in files {
            do {
                try await processPath(f, mode: mode,
                                      recursive: recursive,
                                      attrName: attrName, attrValue: attrValue,
                                      multiple: files.count > 1)
            } catch {
                Shell.bashCurrent.stderr("xattr: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func processPath(_ path: String, mode: Mode,
                             recursive: Bool, attrName: String?, attrValue: String?,
                             multiple: Bool) async throws {
        let resolved = Shell.bashCurrent.resolvePath(path)
        let isDir = (try? await Shell.bashCurrent.fileSystem.metadata(resolved))?.kind == .directory

        try await processOne(path, resolved: resolved, mode: mode,
                             attrName: attrName, attrValue: attrValue,
                             multiple: multiple)

        if recursive, isDir {
            let entries = ((try? await Shell.bashCurrent.fileSystem.list(resolved)) ?? [])
                .map(\.name)
            for name in entries.sorted() {
                let childPath = (path as NSString).appendingPathComponent(name)
                try await processPath(childPath, mode: mode,
                                      recursive: recursive,
                                      attrName: attrName, attrValue: attrValue,
                                      multiple: true)
            }
        }
    }

    private func processOne(_ path: String, resolved: String, 
                            mode: Mode, attrName: String?, attrValue: String?,
                            multiple: Bool) async throws {
        let prefix = multiple ? "\(path): " : ""
        let fs = Shell.bashCurrent.fileSystem
        switch mode {
        case .list:
            let names = try await fs.listXattrs(resolved)
            for n in names { Shell.bashCurrent.stdout(prefix + n + "\n") }
        case .listLong:
            let names = try await fs.listXattrs(resolved)
            for n in names {
                let v = (try? await fs.getXattr(resolved, name: n)) ?? Data()
                let str = String(decoding: v, as: UTF8.self)
                Shell.bashCurrent.stdout("\(prefix)\(n): \(str)\n")
            }
        case .print:
            guard let n = attrName else { return }
            let v = try await fs.getXattr(resolved, name: n)
            Shell.bashCurrent.stdout(prefix + String(decoding: v, as: UTF8.self) + "\n")
        case .write:
            guard let n = attrName, let v = attrValue else { return }
            try await fs.setXattr(resolved, name: n, value: Data(v.utf8))
        case .delete:
            guard let n = attrName else { return }
            try await fs.removeXattr(resolved, name: n)
        case .clear:
            let names = try await fs.listXattrs(resolved)
            for n in names {
                try? await fs.removeXattr(resolved, name: n)
            }
        }
    }
}

// Xattr operations now live on the ``FileSystem`` protocol; the
// previous POSIX wrappers were removed in favour of the abstraction.
