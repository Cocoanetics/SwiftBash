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
        switch parseArgs() {
        case .success(let parsed):
            mode = parsed.mode
            recursive = parsed.recursive
            args = parsed.args
        case .failure(let code):
            return code
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
        let options = ProcessOptions(mode: mode, recursive: recursive,
                                     attrName: attrName, attrValue: attrValue)
        for file in files {
            do {
                try await processPath(file, options: options, multiple: files.count > 1)
            } catch {
                Shell.bashCurrent.stderr("xattr: \(file): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private struct ParsedArgs {
        var mode: Mode
        var recursive: Bool
        var args: [String]
    }

    private enum ArgResult {
        case success(ParsedArgs)
        case failure(ExitStatus)
    }

    // Argv loop: walks single-flag forms (-l/-p/-w/-d/-c/-r) plus
    // bundled forms like `-lr`. Each char arm sets one field; the
    // bundled inner switch shares the same dispatch table — pulling
    // it apart would just duplicate the mode mapping.
    // swiftlint:disable:next cyclomatic_complexity
    private func parseArgs() -> ArgResult {
        var mode: Mode = .list
        var recursive = false
        var args: [String] = []
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count { args.append(rawArgv[index]); index += 1 }
                break
            }
            switch arg {
            case "-l": mode = .listLong; index += 1; continue
            case "-p": mode = .print; index += 1; continue
            case "-w": mode = .write; index += 1; continue
            case "-d": mode = .delete; index += 1; continue
            case "-c": mode = .clear; index += 1; continue
            case "-r": recursive = true; index += 1; continue
            default: break
            }
            // Combined short flags like -lr.
            if arg.hasPrefix("-") && arg.count > 1 && arg != "-" {
                for char in arg.dropFirst() {
                    switch char {
                    case "l": mode = .listLong
                    case "p": mode = .print
                    case "w": mode = .write
                    case "d": mode = .delete
                    case "c": mode = .clear
                    case "r": recursive = true
                    default:
                        Shell.bashCurrent.stderr("xattr: unknown option: -\(char)\n")
                        return .failure(ExitStatus(2))
                    }
                }
                index += 1; continue
            }
            args.append(arg); index += 1
        }
        return .success(ParsedArgs(mode: mode, recursive: recursive, args: args))
    }

    private struct ProcessOptions {
        let mode: Mode
        let recursive: Bool
        let attrName: String?
        let attrValue: String?
    }

    private func processPath(_ path: String, options: ProcessOptions,
                             multiple: Bool) async throws {
        let resolved = Shell.bashCurrent.resolvePath(path)
        let isDir = (try? await Shell.bashCurrent.fileSystem.metadata(resolved))?.kind == .directory

        try await processOne(path, resolved: resolved, options: options, multiple: multiple)

        if options.recursive, isDir {
            let entries = ((try? await Shell.bashCurrent.fileSystem.list(resolved)) ?? [])
                .map(\.name)
            for name in entries.sorted() {
                let childPath = (path as NSString).appendingPathComponent(name)
                try await processPath(childPath, options: options, multiple: true)
            }
        }
    }

    // Mode dispatch: per-Mode switch over the six xattr operations.
    // Each case is a few lines but they all share the same `fileSystem`
    // + `prefix` locals; per-case helpers would force several params
    // through.
    // swiftlint:disable:next cyclomatic_complexity
    private func processOne(_ path: String, resolved: String,
                            options: ProcessOptions, multiple: Bool) async throws {
        let prefix = multiple ? "\(path): " : ""
        let fileSystem = Shell.bashCurrent.fileSystem
        switch options.mode {
        case .list:
            let names = try await fileSystem.listXattrs(resolved)
            for name in names { Shell.bashCurrent.stdout(prefix + name + "\n") }
        case .listLong:
            let names = try await fileSystem.listXattrs(resolved)
            for name in names {
                let data = (try? await fileSystem.getXattr(resolved, name: name)) ?? Data()
                // swiftlint:disable:next optional_data_string_conversion
                let str = String(decoding: data, as: UTF8.self)
                Shell.bashCurrent.stdout("\(prefix)\(name): \(str)\n")
            }
        case .print:
            guard let name = options.attrName else { return }
            let data = try await fileSystem.getXattr(resolved, name: name)
            // swiftlint:disable:next optional_data_string_conversion
            Shell.bashCurrent.stdout(prefix + String(decoding: data, as: UTF8.self) + "\n")
        case .write:
            guard let name = options.attrName, let value = options.attrValue else { return }
            try await fileSystem.setXattr(resolved, name: name, value: Data(value.utf8))
        case .delete:
            guard let name = options.attrName else { return }
            try await fileSystem.removeXattr(resolved, name: name)
        case .clear:
            let names = try await fileSystem.listXattrs(resolved)
            for name in names {
                try? await fileSystem.removeXattr(resolved, name: name)
            }
        }
    }
}

// Xattr operations now live on the ``FileSystem`` protocol; the
// previous POSIX wrappers were removed in favour of the abstraction.
