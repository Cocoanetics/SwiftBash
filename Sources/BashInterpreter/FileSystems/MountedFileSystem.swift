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
        //
        // Use `Shell.normalizePath` (purely lexical) rather than
        // `NSString.standardizingPath`, which consults the host
        // filesystem and resolves any symlinks it finds. On macOS
        // `/home` is an autofs symlink to `/System/Volumes/Data/home`,
        // so `(/home/..) standardizingPath` yields
        // `/System/Volumes/Data` and misses the mount table entirely —
        // breaking any script that lands a `..`-crossing virtual path
        // here (e.g. tab completion of `cd ../ex` from `/home`).
        let std = Shell.normalizePath(virtual)
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

    private func gateRead(_ path: String) async throws -> String {
        guard let r = resolve(path) else {
            throw FileSystemError.notFound(path)
        }
        return try await canonicalGate(r, virtual: path)
    }

    private func gateWrite(_ path: String) async throws -> String {
        guard let r = resolve(path) else {
            throw FileSystemError.notFound(path)
        }
        if r.mount.readOnly {
            throw FileSystemError.permissionDenied(path)
        }
        return try await canonicalGate(r, virtual: path)
    }

    /// Resolve symlinks on the host side and re-verify the canonical
    /// host path is still inside the mount's host root. Without this
    /// step a symlink stored under the mount could point to `/etc`,
    /// `/Users`, or anywhere else on the real disk and the gate would
    /// happily delegate the read to the backing FS — undermining the
    /// chrooted-shell guarantee scripts depend on.
    ///
    /// Synthetic-bin paths (`/bin/cat`, `/usr/bin/grep`, etc.) skip
    /// the canonical check: they're handed off to
    /// `VirtualBinFileSystem` which synthesises responses from the
    /// command registry, not from disk.
    private func canonicalGate(_ r: (mount: Mount, host: String),
                               virtual: String) async throws -> String {
        if isSyntheticBinPath(virtual) { return r.host }
        // Canonicalise BOTH sides via the deepest-existing-ancestor
        // walk. On Windows / NTFS `canonicalize(allowMissing: true)`
        // doesn't expand shortname components (`RUNNER~1` →
        // `runneradmin`) when the leaf doesn't exist yet, so a write
        // to a brand-new file under a mount whose host *does* exist
        // would normalise asymmetrically and trip the prefix check
        // even though the path is genuinely inside the mount.
        // Walking up to the deepest existing parent and
        // canonicalising THAT yields a normalised prefix we can
        // safely compare.
        let canonicalPath: String
        let canonicalRoot: String
        do {
            canonicalPath = try await canonicalizeDeepest(r.host)
            canonicalRoot = try await canonicalizeDeepest(r.mount.host)
        } catch {
            throw FileSystemError.notFound(virtual)
        }
        // Path-component comparison via URL keeps the check
        // separator-agnostic — Windows backslashes, Unix forward
        // slashes, mixed case on NTFS all roll up the same way.
        let pathComps = URL(fileURLWithPath: canonicalPath)
            .standardizedFileURL.pathComponents
        let rootComps = URL(fileURLWithPath: canonicalRoot)
            .standardizedFileURL.pathComponents
        guard pathComps.starts(with: rootComps) else {
            // Symlink (or `..` traversal that survived
            // standardisation) escaped the mount. Hide the host
            // path; report ENOENT against the virtual path.
            throw FileSystemError.notFound(virtual)
        }
        return r.host
    }

    /// Resolve `path` to its canonical form by walking up to the
    /// deepest ancestor that actually exists, canonicalising that,
    /// and re-attaching the missing tail components.
    ///
    /// This sidesteps a Windows-only quirk: `canonicalize(_,
    /// allowMissing: true)` on a non-existent path may leave shortname
    /// components (`RUNNER~1`) un-expanded because the OS APIs that
    /// expand them require an existing inode to query. Once we've
    /// canonicalised an existing prefix, the result is a stable form
    /// that compares correctly against any other deepest-ancestor
    /// resolution under the same root.
    private func canonicalizeDeepest(_ path: String) async throws -> String {
        var probe = (path as NSString).standardizingPath
        var tail: [String] = []
        while !probe.isEmpty {
            if let canon = try? await backing.canonicalize(probe,
                                                           allowMissing: false) {
                return tail.reversed().reduce(canon) { acc, name in
                    (acc as NSString).appendingPathComponent(name)
                }
            }
            let parent = (probe as NSString).deletingLastPathComponent
            let leaf = (probe as NSString).lastPathComponent
            // `deletingLastPathComponent` on `/` returns `/` — bail
            // out before we loop forever. Same for Windows volume
            // roots like `C:\` where the parent is itself.
            if parent == probe || leaf.isEmpty { break }
            tail.append(leaf)
            probe = parent
        }
        // Nothing on the path exists. Fall back to lexical
        // standardisation so the caller still has a usable string;
        // the prefix check downstream will fail naturally if this
        // path isn't under any real mount.
        return (path as NSString).standardizingPath
    }

    // MARK: - FileSystem conformance

    public func metadata(_ path: String) async throws -> FileMetadata? {
        // "Outside the mount table" looks like ENOENT to scripts —
        // not a thrown error, just `nil`, so test idioms like
        // `[ -f /etc/passwd ]` behave as on a chrooted shell.
        guard let r = resolve(path) else { return nil }
        // The same chrooted-shell answer for symlinks escaping the
        // mount: report nil rather than a thrown error so `[ -f ]`
        // tests stay quiet.
        let host: String
        do {
            host = try await canonicalGate(r, virtual: path)
        } catch FileSystemError.notFound {
            return nil
        }
        return try await backing.metadata(host)
    }

    public func list(_ path: String) async throws -> [String] {
        try await backing.list(try await gateRead(path))
    }

    public func canonicalize(_ path: String,
                             allowMissing: Bool) async throws -> String {
        // Important: return the VIRTUAL path back, not the host one.
        // Otherwise `realpath /home/foo` leaks the host path into
        // the script's view.
        guard let r = resolve(path) else {
            throw FileSystemError.notFound(path)
        }
        // Verify the host path is canonicalisable AND that any
        // symlink chain stays inside the mount.
        _ = try await canonicalGate(r, virtual: path)
        if !allowMissing {
            // Honour the contract: throw if the path doesn't exist
            // and `allowMissing == false`.
            _ = try await backing.canonicalize(r.host, allowMissing: false)
        }
        return (path as NSString).standardizingPath
    }

    public func readData(_ path: String) async throws -> Data {
        try await backing.readData(try await gateRead(path))
    }

    public func openRead(_ path: String) async throws -> InputSource {
        try await backing.openRead(try await gateRead(path))
    }

    public func writeData(_ data: Data, to path: String,
                          append: Bool) async throws {
        try await backing.writeData(data, to: try await gateWrite(path),
                                    append: append)
    }

    public func openWrite(_ path: String,
                          append: Bool) async throws -> OutputSink {
        try await backing.openWrite(try await gateWrite(path), append: append)
    }

    public func touch(_ path: String) async throws {
        try await backing.touch(try await gateWrite(path))
    }

    public func createDirectory(_ path: String,
                                intermediates: Bool) async throws {
        try await backing.createDirectory(try await gateWrite(path),
                                          intermediates: intermediates)
    }

    public func remove(_ path: String, recursive: Bool) async throws {
        try await backing.remove(try await gateWrite(path), recursive: recursive)
    }

    public func move(from: String, to: String) async throws {
        try await backing.move(from: try await gateWrite(from),
                               to: try await gateWrite(to))
    }

    public func copy(from: String, to: String) async throws {
        try await backing.copy(from: try await gateRead(from),
                               to: try await gateWrite(to))
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
        if let host = try? await gateWrite(fallback) {
            try? await backing.createDirectory(
                (host as NSString).deletingLastPathComponent,
                intermediates: true)
        }
        return fallback
    }

    public func chmod(_ path: String, mode: UInt16) async throws {
        try await backing.chmod(try await gateWrite(path), mode: mode)
    }

    public func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
        try await backing.chown(try await gateWrite(path), uid: uid, gid: gid)
    }

    public func symlink(target: String, at linkPath: String) async throws {
        // Symlink targets are stored verbatim — they may be relative
        // (`ln -s foo bar`) or absolute, and resolution happens at
        // *use* time through the same gate as any other path access.
        // Translating the target through `gateRead` would (a) break
        // relative-target semantics and (b) leak the host's mount
        // path into the link's stored target text. Only the link
        // *site* needs to be remapped through the mount table.
        try await backing.symlink(target: target,
                                  at: try await gateWrite(linkPath))
    }

    public func hardlink(target: String, at linkPath: String) async throws {
        // Hardlinks resolve immediately to an inode and the target
        // file must already exist, so gate the read side too — the
        // `target` stored on disk is the path used at link-creation
        // time, not text resolved later.
        try await backing.hardlink(target: try await gateRead(target),
                                   at: try await gateWrite(linkPath))
    }

    public func listXattrs(_ path: String) async throws -> [String] {
        try await backing.listXattrs(try await gateRead(path))
    }

    public func getXattr(_ path: String, name: String) async throws -> Data {
        try await backing.getXattr(try await gateRead(path), name: name)
    }

    public func setXattr(_ path: String, name: String, value: Data) async throws {
        try await backing.setXattr(try await gateWrite(path),
                                   name: name, value: value)
    }

    public func removeXattr(_ path: String, name: String) async throws {
        try await backing.removeXattr(try await gateWrite(path), name: name)
    }
}
