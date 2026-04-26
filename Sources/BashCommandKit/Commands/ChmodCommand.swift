import ArgumentParser
import BashInterpreter
import Foundation

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

    public mutating func execute() async throws -> ExitStatus {
        guard operands.count >= 2 else {
            Shell.current.stderr("chmod: missing operand\n")
            return ExitStatus(2)
        }
        let modeStr = operands[0]
        guard let mode = UInt16(modeStr, radix: 8) else {
            Shell.current.stderr("chmod: invalid mode: \(modeStr)\n")
            return ExitStatus(2)
        }
        var hadError = false
        for f in operands.dropFirst() {
            let resolved = Shell.current.resolvePath(f)
            do {
                try await Shell.current.fileSystem.chmod(resolved, mode: mode)
                if recursive {
                    try await applyRecursive(resolved, mode: mode)
                }
            } catch {
                Shell.current.stderr("chmod: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func applyRecursive(_ path: String, mode: UInt16) async throws {
        guard let meta = try? await Shell.current.fileSystem.metadata(path),
              meta.kind == .directory else { return }
        let entries = (try? await Shell.current.fileSystem.list(path)) ?? []
        for name in entries {
            let child = (path as NSString).appendingPathComponent(name)
            try? await Shell.current.fileSystem.chmod(child, mode: mode)
            try await applyRecursive(child, mode: mode)
        }
    }
}
