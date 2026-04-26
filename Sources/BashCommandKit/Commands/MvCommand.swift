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

    public mutating func execute() async throws -> ExitStatus {
        guard paths.count >= 2 else {
            Shell.current.stderr("mv: missing operand\n")
            return .failure
        }
        let sources = paths.dropLast()
        let dest = paths.last!
        let destAbs = Shell.current.resolvePath(dest)
        let destMeta = try? await Shell.current.fileSystem.metadata(destAbs)
        let destIsDir = destMeta?.kind == .directory

        if sources.count > 1 && !destIsDir {
            Shell.current.stderr("mv: target `\(dest)` is not a directory\n")
            return .failure
        }

        var hadError = false
        for src in sources {
            let srcAbs = Shell.current.resolvePath(src)
            let finalDest: String = destIsDir
                ? (destAbs as NSString).appendingPathComponent(
                    (srcAbs as NSString).lastPathComponent)
                : destAbs
            do {
                try await Shell.current.fileSystem.move(from: srcAbs, to: finalDest)
            } catch {
                Shell.current.stderr("mv: \(src): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}

#if canImport(Foundation)
import Foundation
#endif
