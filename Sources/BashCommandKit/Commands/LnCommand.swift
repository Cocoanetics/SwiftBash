import ArgumentParser
import BashInterpreter
import Foundation

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

    public mutating func execute() async throws -> ExitStatus {
        guard operands.count >= 2 else {
            Shell.bashCurrent.stderr("ln: missing operand\n")
            return ExitStatus(2)
        }
        let last = operands.last!
        let lastResolved = Shell.bashCurrent.resolvePath(last)
        let isDir = (try? await Shell.bashCurrent.fileSystem.metadata(lastResolved))?.kind == .directory
        let targets: [String]
        var destination: String
        if isDir && operands.count > 2 {
            targets = Array(operands.dropLast())
            destination = lastResolved
        } else if operands.count == 2 {
            targets = [operands[0]]
            destination = lastResolved
        } else {
            Shell.bashCurrent.stderr("ln: target '\(last)' is not a directory\n")
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
                if force, let _ = try? await Shell.bashCurrent.fileSystem.metadata(dest) {
                    try? await Shell.bashCurrent.fileSystem.remove(dest, recursive: false)
                }
                if symbolic {
                    try await Shell.bashCurrent.fileSystem.symlink(target: target, at: dest)
                } else {
                    try await Shell.bashCurrent.fileSystem.hardlink(
                        target: Shell.bashCurrent.resolvePath(target), at: dest)
                }
            } catch {
                Shell.bashCurrent.stderr("ln: \(dest): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
