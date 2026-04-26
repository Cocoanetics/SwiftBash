import ArgumentParser
import BashInterpreter
import Foundation

/// `cp [-r] SOURCE... DEST` — copy files (or directories with `-r`).
public struct CpCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "Copy files and directories."
    )

    @Argument(help: "Source paths followed by the destination.")
    public var paths: [String] = []

    @Flag(name: [.customShort("r"), .customLong("recursive"),
                 .customShort("R")],
          help: "Recurse into directories.")
    public var recursive: Bool = false

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        guard paths.count >= 2 else {
            Shell.current.stderr("cp: missing operand\n")
            return .failure
        }
        let sources = paths.dropLast()
        let dest = paths.last!
        let destAbs = Shell.current.resolvePath(dest)
        let destMeta = try? await Shell.current.fileSystem.metadata(destAbs)
        let destIsDir = destMeta?.kind == .directory

        if sources.count > 1 && !destIsDir {
            Shell.current.stderr("cp: target `\(dest)` is not a directory\n")
            return .failure
        }

        var hadError = false
        for src in sources {
            let srcAbs = Shell.current.resolvePath(src)
            let srcMeta = try? await Shell.current.fileSystem.metadata(srcAbs)
            if srcMeta?.kind == .directory && !recursive {
                Shell.current.stderr("cp: \(src): is a directory (use -r)\n")
                hadError = true
                continue
            }
            let finalDest: String = destIsDir
                ? (destAbs as NSString).appendingPathComponent(
                    (srcAbs as NSString).lastPathComponent)
                : destAbs
            do {
                try await Shell.current.fileSystem.copy(from: srcAbs, to: finalDest)
            } catch {
                Shell.current.stderr("cp: \(src): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
