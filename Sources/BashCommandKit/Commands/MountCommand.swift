import ArgumentParser
import BashInterpreter

/// `mount` — show the shell's virtual mount table.
///
/// SwiftBash has no host mount table; this lists the
/// ``MountedFileSystem`` entries the embedder wired up — each virtual
/// prefix, the host directory backing it, and whether it's read-only —
/// in a `mount`-style line:
///
/// ```
/// /private/tmp/sandbox on / type sandbox (ro)
/// /private/tmp/sandbox/home on /home type sandbox (rw)
/// /private/tmp/scratch on /tmp type sandbox (rw)
/// ```
///
/// Operands are accepted and ignored — this is a read-only view of the
/// sandbox, not a way to mount new filesystems inside it. A shell with
/// no `MountedFileSystem` (e.g. a plain in-memory root) prints nothing.
public struct MountCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mount",
        abstract: "Show the virtual mount table."
    )

    @Argument(parsing: .captureForPassthrough, help: "(ignored)")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        guard let mounted = Self.mountedFileSystem(
            of: Shell.bashCurrent.fileSystem) else {
            return .success
        }
        for mount in mounted.mountList {
            let options = mount.readOnly ? "ro" : "rw"
            Shell.bashCurrent.stdout(
                "\(mount.host) on \(mount.virtual) type sandbox (\(options))\n")
        }
        return .success
    }

    /// Walk the shell's filesystem stack — an `OverlayFileSystem` wraps
    /// the mount table — to find the underlying ``MountedFileSystem``.
    static func mountedFileSystem(
        of fileSystem: any FileSystem) -> MountedFileSystem? {
        if let mounted = fileSystem as? MountedFileSystem { return mounted }
        if let overlay = fileSystem as? OverlayFileSystem {
            return mountedFileSystem(of: overlay.backing)
        }
        return nil
    }
}
