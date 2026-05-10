import Foundation

/// A `FileSystem` that presents a virtual root (`/`) backed by one or
/// more host directories mounted at chosen virtual prefixes.
///
/// Embedders building "iOS-app-as-sandbox" experiences want:
///
/// - `/` to be the user's writable workspace, NOT the host's real
///   `/Users/oliver/Library/.../Documents/Untitled.ibash` — which
///   leaks into `pwd`, error diagnostics, `$0`, and basically every
///   path the script sees;
/// - `/tmp` to mean the OS temp directory (so `mktemp`, `$TMPDIR`,
///   etc. work the way scripts expect, but persisted state stays
///   under the document package);
/// - everything else (`/etc`, `/usr`, `/Users`) to look as if it
///   doesn't exist — same model as a chrooted shell.
///
/// `MountedFileSystem` is the building block for that. You hand it a
/// list of mount points and a backing FS; it rewrites every virtual
/// path to a host path before delegating, and rejects paths that
/// don't fall inside any mount with `notFound`.
///
/// ```swift
/// let fs = MountedFileSystem(
///     mounts: [
///         .init(virtual: "/",    host: sandboxRoot.path),
///         .init(virtual: "/tmp", host: NSTemporaryDirectory()),
///     ],
///     backing: RealFileSystem())
/// shell.fileSystem = fs
/// shell.environment.workingDirectory = "/home"
/// shell.environment["HOME"] = "/home"
/// shell.environment["TMPDIR"] = "/tmp"
/// ```
///
/// Mount precedence is "longest virtual prefix wins" — `/tmp/foo`
/// matches the `/tmp` mount, not `/`. Synthetic `/bin/*` paths
/// supplied by `VirtualBinFileSystem` always fall through (so
/// `which cat` still resolves) regardless of mounts.
public final class MountedFileSystem: FileSystem, @unchecked Sendable {

    public struct Mount: Sendable {
        /// Virtual prefix this mount answers to. `/` matches every
        /// virtual path; `/tmp` matches `/tmp` and `/tmp/...`.
        public var virtual: String
        /// Absolute host path the mount maps onto.
        public var host: String
        /// If true, every write through this mount is rejected with
        /// `permissionDenied`. Reads still pass.
        public var readOnly: Bool

        public init(virtual: String, host: String, readOnly: Bool = false) {
            // Normalise: strip trailing `/` so `/tmp` and `/tmp/`
            // compare equal. The empty string represents the root
            // mount specially.
            var v = (virtual as NSString).standardizingPath
            if v.count > 1, v.hasSuffix("/") { v.removeLast() }
            self.virtual = v
            self.host = (host as NSString).standardizingPath
            self.readOnly = readOnly
        }
    }

    public let backing: any FileSystem
    private let mounts: [Mount]

    public init(mounts: [Mount], backing: any FileSystem) {
        // Sort longest-prefix-first so prefix matching picks the
        // most specific mount.
        self.mounts = mounts.sorted { $0.virtual.count > $1.virtual.count }
        self.backing = backing
    }

    // MARK: - Mount lookup

    /// Translate a virtual path to a host path, or return `nil` when
    /// no mount matches. `(mount, hostPath, readOnly)`.
    private func resolve(_ virtual: String) -> (mount: Mount, host: String)? {
        // Synthetic /bin paths are handed verbatim to the backing FS
        // (VirtualBinFileSystem expects them at the virtual position
        // they advertise). Don't try to remap.
        if isSyntheticBinPath(virtual) {
            return (Mount(virtual: "/__virtual_bin__", host: virtual,
                          readOnly: true),
                    virtual)
        }
        // Standardise the virtual path so `/tmp/../home/foo` resolves
        // to `/home/foo` BEFORE we route it. Otherwise `..` could
        // escape its mount.
        let std = (virtual as NSString).standardizingPath
        for mount in mounts {
            if mount.virtual == "/" {
                // Root mount — every path lands here unless an earlier
                // (more specific) mount matched. Strip the leading `/`
                // and append.
                let rel = std == "/" ? "" : String(std.dropFirst())
                let host = (mount.host as NSString)
                    .appendingPathComponent(rel)
                return (mount, host)
            }
            if std == mount.virtual {
                return (mount, mount.host)
            }
            if std.hasPrefix(mount.virtual + "/") {
                let rel = String(std.dropFirst(mount.virtual.count + 1))
                let host = (mount.host as NSString)
                    .appendingPathComponent(rel)
                return (mount, host)
            }
        }
        return nil
    }

    private func isSyntheticBinPath(_ path: String) -> Bool {
        let dirs: Set<String> = ["/bin", "/usr/bin", "/usr/local/bin"]
        if dirs.contains(path) { return true }
        let parent = (path as NSString).deletingLastPathComponent
        return dirs.contains(parent)
    }

    private func gateRead(_ path: String) throws -> String {
        guard let r = resolve(path) else {
            throw FileSystemError.notFound(path)
        }
        return r.host
    }

    private func gateWrite(_ path: String) throws -> String {
        guard let r = resolve(path) else {
            throw FileSystemError.notFound(path)
        }
        if r.mount.readOnly {
            throw FileSystemError.permissionDenied(path)
        }
        return r.host
    }

    // MARK: - FileSystem conformance

    public func metadata(_ path: String) async throws -> FileMetadata? {
        // "Outside the mount table" looks like ENOENT to scripts —
        // not a thrown error, just `nil`, so test idioms like
        // `[ -f /etc/passwd ]` behave as on a chrooted shell.
        guard let r = resolve(path) else { return nil }
        return try await backing.metadata(r.host)
    }

    public func list(_ path: String) async throws -> [String] {
        try await backing.list(try gateRead(path))
    }

    public func canonicalize(_ path: String,
                             allowMissing: Bool) async throws -> String {
        // Important: return the VIRTUAL path back, not the host one.
        // Otherwise `realpath /home/foo` leaks the host path into
        // the script's view.
        guard let r = resolve(path) else {
            throw FileSystemError.notFound(path)
        }
        // Verify the host path is canonicalisable; let the backing FS
        // throw notFound if `allowMissing == false` and nothing's there.
        _ = try await backing.canonicalize(r.host, allowMissing: allowMissing)
        return (path as NSString).standardizingPath
    }

    public func readData(_ path: String) async throws -> Data {
        try await backing.readData(try gateRead(path))
    }

    public func openRead(_ path: String) async throws -> InputSource {
        try await backing.openRead(try gateRead(path))
    }

    public func writeData(_ data: Data, to path: String,
                          append: Bool) async throws {
        try await backing.writeData(data, to: try gateWrite(path), append: append)
    }

    public func openWrite(_ path: String,
                          append: Bool) async throws -> OutputSink {
        try await backing.openWrite(try gateWrite(path), append: append)
    }

    public func touch(_ path: String) async throws {
        try await backing.touch(try gateWrite(path))
    }

    public func createDirectory(_ path: String,
                                intermediates: Bool) async throws {
        try await backing.createDirectory(try gateWrite(path),
                                          intermediates: intermediates)
    }

    public func remove(_ path: String, recursive: Bool) async throws {
        try await backing.remove(try gateWrite(path), recursive: recursive)
    }

    public func move(from: String, to: String) async throws {
        try await backing.move(from: try gateWrite(from),
                               to: try gateWrite(to))
    }

    public func copy(from: String, to: String) async throws {
        try await backing.copy(from: try gateRead(from),
                               to: try gateWrite(to))
    }

    public func makeTempPath(prefix: String) async throws -> String {
        // If the mount table covers `/tmp`, defer to the backing FS
        // there. Otherwise drop into a hidden `.tmp` directory under
        // the root mount.
        if let tmp = mounts.first(where: { $0.virtual == "/tmp" }), !tmp.readOnly {
            try? await backing.createDirectory(tmp.host, intermediates: true)
            let suffix = String(UUID().uuidString.prefix(12))
            return "/tmp/\(prefix)\(suffix)"
        }
        let fallback = "/.tmp/\(prefix)\(UUID().uuidString.prefix(12))"
        if let host = try? gateWrite(fallback) {
            try? await backing.createDirectory(
                (host as NSString).deletingLastPathComponent,
                intermediates: true)
        }
        return fallback
    }

    public func chmod(_ path: String, mode: UInt16) async throws {
        try await backing.chmod(try gateWrite(path), mode: mode)
    }

    public func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
        try await backing.chown(try gateWrite(path), uid: uid, gid: gid)
    }

    public func symlink(target: String, at linkPath: String) async throws {
        // Both ends are virtual — guard them both, then translate.
        try await backing.symlink(target: try gateRead(target),
                                  at: try gateWrite(linkPath))
    }

    public func hardlink(target: String, at linkPath: String) async throws {
        try await backing.hardlink(target: try gateRead(target),
                                   at: try gateWrite(linkPath))
    }

    public func listXattrs(_ path: String) async throws -> [String] {
        try await backing.listXattrs(try gateRead(path))
    }

    public func getXattr(_ path: String, name: String) async throws -> Data {
        try await backing.getXattr(try gateRead(path), name: name)
    }

    public func setXattr(_ path: String, name: String, value: Data) async throws {
        try await backing.setXattr(try gateWrite(path),
                                   name: name, value: value)
    }

    public func removeXattr(_ path: String, name: String) async throws {
        try await backing.removeXattr(try gateWrite(path), name: name)
    }
}
