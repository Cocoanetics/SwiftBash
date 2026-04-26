import ArgumentParser
import BashInterpreter
import Foundation

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

    public mutating func execute() async throws -> ExitStatus {
        guard !files.isEmpty else {
            Shell.current.stderr("readlink: missing operand\n")
            return ExitStatus(2)
        }
        var hadError = false
        for f in files {
            let resolved = Shell.current.resolvePath(f)
            if canonicalize {
                if let canonical = try? await Shell.current.fileSystem
                    .canonicalize(resolved, allowMissing: true) {
                    Shell.current.stdout(canonical + "\n")
                } else {
                    Shell.current.stdout(resolved + "\n")
                }
                continue
            }
            guard let meta = try? await Shell.current.fileSystem.metadata(resolved) else {
                Shell.current.stderr("readlink: \(f): No such file or directory\n")
                hadError = true; continue
            }
            if let target = meta.symlinkTarget {
                Shell.current.stdout(target + "\n")
            } else {
                Shell.current.stderr("readlink: \(f): Not a symlink\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
