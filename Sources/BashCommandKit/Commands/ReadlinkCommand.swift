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
            Shell.bashCurrent.stderr("readlink: missing operand\n")
            return ExitStatus(2)
        }
        var hadError = false
        for file in files {
            let resolved = Shell.bashCurrent.resolvePath(file)
            if canonicalize {
                if let canonical = try? await Shell.bashCurrent.fileSystem
                    .canonicalize(resolved, allowMissing: true) {
                    Shell.bashCurrent.stdout(canonical + "\n")
                } else {
                    Shell.bashCurrent.stdout(resolved + "\n")
                }
                continue
            }
            guard let meta = try? await Shell.bashCurrent.fileSystem.metadata(resolved) else {
                Shell.bashCurrent.stderr("readlink: \(file): No such file or directory\n")
                hadError = true; continue
            }
            if let target = meta.symlinkTarget {
                Shell.bashCurrent.stdout(target + "\n")
            } else {
                Shell.bashCurrent.stderr("readlink: \(file): Not a symlink\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
