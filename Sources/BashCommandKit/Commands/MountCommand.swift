import ArgumentParser
import BashInterpreter

/// `mount` — show the shell's virtual mount table.
///
/// SwiftBash has no host mount table; this lists the
/// ``MountedFileSystem`` entries the embedder wired up — each virtual
/// prefix and whether it's read-only — in a `mount`-style line. The
/// host directory backing each mount is deliberately **not** shown, so
/// host paths stay out of the sandbox (matching `pwd` / `realpath` /
/// diagnostics); the device column is a synthetic `sandbox` label:
///
/// ```
/// sandbox on / type sandbox (ro)
/// sandbox on /home type sandbox (rw)
/// sandbox on /tmp type sandbox (rw)
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
        let table = mounted.mountList
        var seen = Set<String>()
        for mount in table {
            // Resolve the mountpoint to its virtual spelling before
            // printing. Some mounts exist only as a real-path alias: the
            // CLI mounts `$TMPDIR`'s host path (e.g. `/var/folders/…/T`)
            // next to `/tmp` so `$TMPDIR` resolves, and printing that
            // virtual verbatim would leak a host path. When another mount
            // exposes this one's `virtual` (itself a host path) under a
            // cleaner name, print that name; the de-dup below then folds
            // the alias into `/tmp`. A genuine `/tmp → /tmp` mount (Linux,
            // where `NSTemporaryDirectory()` normalises to `/tmp`) has no
            // such alias and stays visible.
            let mountPoint = table.first {
                $0.host == mount.virtual && $0.virtual != mount.virtual
            }?.virtual ?? mount.virtual
            guard seen.insert(mountPoint).inserted else { continue }
            let options = mount.readOnly ? "ro" : "rw"
            // Synthetic `sandbox` device — never the real `mount.host`
            // backing path, which would leak the host workspace / temp
            // container path into the sandbox.
            Shell.bashCurrent.stdout(
                "sandbox on \(mountPoint) type sandbox (\(options))\n")
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
