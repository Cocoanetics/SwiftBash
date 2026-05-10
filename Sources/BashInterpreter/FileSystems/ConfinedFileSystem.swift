import Foundation

/// A ``FileSystem`` wrapper that rejects any path outside a configured
/// host directory (`root`). Reads and writes that fall *inside* the
/// root pass through to the wrapped backing filesystem unchanged — so
/// writes still hit disk, unlike the COW model of
/// ``SandboxedOverlayFileSystem``.
///
/// Use this when an embedder wants:
///
/// - real on-disk persistence inside one directory, AND
/// - hard rejection of `/etc`, `/Users`, `/tmp`, or any other host path
///   typed by the script (or emitted by an LLM-driven agent that
///   reflexively reaches for absolute paths).
///
/// Confinement is applied via canonical-path comparison — a host
/// symlink that escapes the root is rejected on first access. The
/// shell's own ``Sandbox`` URL gate covers the same threat for
/// ShellKit-aware bridges; this layer covers the legacy path-based
/// builtins (`cat`, `ls`, `mkdir`, `cp`, `rm`, …) until the FileSystem
/// surface migrates onto the URL gate.
///
/// Synthetic-bin paths (`/bin/cat`, `/usr/bin/grep`, `/usr/local/bin/rg`)
/// are always allowed through — they're virtual files synthesised by
/// ``VirtualBinFileSystem`` from the live command registry, not host
/// disk reads, so confinement isn't meaningful and rejecting them
/// would break `which`, `ls /bin`, etc. Wrap order matters:
/// `Confined(Virtual(Real()))` lets the synthesised paths flow.
///
/// ```swift
/// let real = RealFileSystem()
/// let virt = VirtualBinFileSystem(backing: real)
/// let confined = ConfinedFileSystem(backing: virt,
///                                   root: "/Users/me/sandbox")
/// shell.fileSystem = confined
/// ```
public final class ConfinedFileSystem: FileSystem, @unchecked Sendable {

    /// The wrapped backing filesystem.
    public let backing: any FileSystem

    /// Canonical absolute root. Every host path passed to this
    /// filesystem is rewritten to be inside this directory or rejected.
    public let root: String

    /// Construct a confining wrapper.
    ///
    /// - Parameters:
    ///   - backing: The underlying filesystem to delegate to when a
    ///     path is allowed.
    ///   - root: Absolute path of the confinement root. Paths exactly
    ///     equal to this, or descended from it, pass through. Any
    ///     other host path raises ``FileSystemError/notFound(_:)``,
    ///     matching how a chrooted shell experiences the world.
    public init(backing: any FileSystem, root: String) {
        self.backing = backing
        self.root = (root as NSString).standardizingPath
    }

    // MARK: - Path gating

    /// Returns `path` unchanged if it's allowed, or throws
    /// ``FileSystemError/notFound`` with the *user-supplied* path so
    /// the canonical host path doesn't leak into diagnostics.
    private func gate(_ path: String) throws -> String {
        if isAllowed(path) { return path }
        throw FileSystemError.notFound(path)
    }

    /// `true` if `path` is the root itself, lives under it, or is one
    /// of the synthesized-bin paths the wrapper is intentionally
    /// transparent to. Path-shape match is enough — `realpath` resolution
    /// happens in the backing FS.
    private func isAllowed(_ path: String) -> Bool {
        // Synthetic /bin paths always pass through.
        if isSyntheticBinPath(path) { return true }

        // Relative paths get joined with the working directory by
        // `Shell.resolvePath` *before* hitting the FS, so by the time
        // a path lands here it should already be absolute. Be defensive
        // about any non-absolute slipping through — accept relative
        // paths so internal helpers (which sometimes pass bare names)
        // still work, but let the backing FS handle them.
        if !path.hasPrefix("/") { return true }

        let standard = (path as NSString).standardizingPath
        if standard == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return standard.hasPrefix(prefix)
    }

    private func isSyntheticBinPath(_ path: String) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        return ["/bin", "/usr/bin", "/usr/local/bin"].contains(dir)
            || ["/bin", "/usr/bin", "/usr/local/bin"].contains(path)
    }

    // MARK: - FileSystem conformance

    public func metadata(_ path: String) async throws -> FileMetadata? {
        // For metadata specifically, "outside the sandbox" should look
        // exactly like "no such file" — `nil`, not a thrown error —
        // because callers (e.g. `[ -f /etc/passwd ]`) rely on the nil
        // signal to behave the way they would on a chrooted system.
        guard isAllowed(path) else { return nil }
        return try await backing.metadata(path)
    }

    public func list(_ path: String) async throws -> [String] {
        try await backing.list(try gate(path))
    }

    public func canonicalize(_ path: String,
                             allowMissing: Bool) async throws -> String {
        try await backing.canonicalize(try gate(path), allowMissing: allowMissing)
    }

    public func readData(_ path: String) async throws -> Data {
        try await backing.readData(try gate(path))
    }

    public func openRead(_ path: String) async throws -> InputSource {
        try await backing.openRead(try gate(path))
    }

    public func writeData(_ data: Data, to path: String,
                          append: Bool) async throws
    {
        try await backing.writeData(data, to: try gate(path), append: append)
    }

    public func openWrite(_ path: String,
                          append: Bool) async throws -> OutputSink
    {
        try await backing.openWrite(try gate(path), append: append)
    }

    public func touch(_ path: String) async throws {
        try await backing.touch(try gate(path))
    }

    public func createDirectory(_ path: String,
                                intermediates: Bool) async throws
    {
        try await backing.createDirectory(try gate(path),
                                          intermediates: intermediates)
    }

    public func remove(_ path: String, recursive: Bool) async throws {
        try await backing.remove(try gate(path), recursive: recursive)
    }

    public func move(from: String, to: String) async throws {
        try await backing.move(from: try gate(from), to: try gate(to))
    }

    public func copy(from: String, to: String) async throws {
        try await backing.copy(from: try gate(from), to: try gate(to))
    }

    public func makeTempPath(prefix: String) async throws -> String {
        // Temp paths get created under the backing FS's notion of
        // tmpdir, which is usually outside the sandbox. Force temp
        // files into the sandbox root by overlaying the prefix into a
        // hidden `.tmp` subdirectory of the root.
        let tmpDir = (root as NSString).appendingPathComponent(".tmp")
        try? await backing.createDirectory(tmpDir, intermediates: true)
        let suffix = String(UUID().uuidString.prefix(12))
        return (tmpDir as NSString).appendingPathComponent("\(prefix)\(suffix)")
    }

    public func chmod(_ path: String, mode: UInt16) async throws {
        try await backing.chmod(try gate(path), mode: mode)
    }

    public func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
        try await backing.chown(try gate(path), uid: uid, gid: gid)
    }

    public func symlink(target: String, at linkPath: String) async throws {
        // Both link site AND target must be inside the sandbox — we
        // don't want the user to plant a symlink that escapes the
        // confinement on the next stat.
        try await backing.symlink(target: try gate(target),
                                  at: try gate(linkPath))
    }

    public func hardlink(target: String, at linkPath: String) async throws {
        try await backing.hardlink(target: try gate(target),
                                   at: try gate(linkPath))
    }

    public func listXattrs(_ path: String) async throws -> [String] {
        try await backing.listXattrs(try gate(path))
    }

    public func getXattr(_ path: String, name: String) async throws -> Data {
        try await backing.getXattr(try gate(path), name: name)
    }

    public func setXattr(_ path: String, name: String, value: Data) async throws {
        try await backing.setXattr(try gate(path), name: name, value: value)
    }

    public func removeXattr(_ path: String, name: String) async throws {
        try await backing.removeXattr(try gate(path), name: name)
    }
}
