import ArgumentParser
import BashInterpreter

/// `mv SOURCE DEST` — rename a file, or move it into a directory.
public struct MvCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mv",
        abstract: "Move or rename a file."
    )

    @Argument(help: "Source paths followed by the destination.")
    public var paths: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        guard paths.count >= 2 else {
            shell.stderr("mv: missing operand\n")
            return .failure
        }
        let sources = paths.dropLast()
        let dest = paths.last!
        let destAbs = shell.resolvePath(dest)
        let destMeta = try? await shell.fileSystem.metadata(destAbs)
        let destIsDir = destMeta?.kind == .directory

        if sources.count > 1 && !destIsDir {
            shell.stderr("mv: target `\(dest)` is not a directory\n")
            return .failure
        }

        var hadError = false
        for src in sources {
            let srcAbs = shell.resolvePath(src)
            let finalDest: String = destIsDir
                ? (destAbs as NSString).appendingPathComponent(
                    (srcAbs as NSString).lastPathComponent)
                : destAbs
            do {
                try await shell.fileSystem.move(from: srcAbs, to: finalDest)
            } catch {
                shell.stderr("mv: \(src): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}

#if canImport(Foundation)
import Foundation
#endif
