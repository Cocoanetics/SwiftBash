import Foundation

/// A ``FileSystem`` wrapper that synthesizes `/bin`, `/usr/bin`, and
/// `/usr/local/bin` from the running shell's command registry.
///
/// Why this exists: the shell never executes real on-disk binaries —
/// every command is dispatched in-process via ``Shell/commands``. So
/// the host's `/bin` and `/usr/bin` are irrelevant; what matters is
/// the set of commands the script can actually invoke. This overlay
/// makes that visible:
///
/// ```bash
/// $ ls /bin
/// cat
/// chmod
/// cp
/// …
/// $ ls /usr/bin | head
/// awk
/// base64
/// …
/// $ stat /bin/cat
/// File: "/bin/cat"
/// Type: regular file (executable)
/// $ which cat
/// /bin/cat
/// ```
///
/// Pure shell built-ins (`cd`, `export`, `exit`, `eval`, `let`, …)
/// don't appear here — they don't appear on real macOS either.
///
/// This wraps another ``FileSystem``: every operation outside the
/// synthesized directories forwards through unchanged. Inside the
/// synthesized directories writes are rejected as `EROFS`-style
/// permission denied — these are virtual.
///
/// The catalog of name → path comes from ``BinCatalog/knownPaths``,
/// intersected with the live ``Shell/current``'s ``Shell/commands``
/// registry. So if you `unregister("cat")`, `/bin/cat` disappears
/// from `ls /bin` immediately.
public final class VirtualBinFileSystem: FileSystem, @unchecked Sendable {

    /// The wrapped backing filesystem. Anything not in `/bin`,
    /// `/usr/bin`, or `/usr/local/bin` (and not on the path leading
    /// to one) is forwarded here.
    public let backing: any FileSystem

    public init(backing: any FileSystem) {
        self.backing = backing
    }

    // MARK: Synthesized directories

    /// Directories whose listings come entirely from the catalog,
    /// not the backing fs.
    private var synthesizedDirectories: Set<String> {
        BinCatalog.knownDirectories
    }

    /// Names registered on the running shell that have a catalog
    /// entry under `directory`. The intersection of "what the shell
    /// can run" and "what would live here on a real macOS install".
    private func synthesizedEntries(in directory: String) -> [String] {
        let registered = Set(Shell.current.commands.keys)
        return BinCatalog.names(in: directory)
            .filter { registered.contains($0) }
            .sorted()
    }

    /// `true` if `path` is a file we synthesize (e.g. `/bin/cat`).
    private func isSynthesizedFile(_ path: String) -> Bool {
        guard let canonical = BinCatalog.knownPaths[
            (path as NSString).lastPathComponent]
        else { return false }
        return canonical == path
            && Shell.current.commands[(path as NSString).lastPathComponent] != nil
    }

    /// `true` if `path` is one of the synthesized directories.
    private func isSynthesizedDir(_ path: String) -> Bool {
        synthesizedDirectories.contains(path)
    }

    // MARK: Inspection

    public func metadata(_ path: String) async throws -> FileMetadata? {
        if isSynthesizedFile(path) {
            return Self.fileMetadata(path: path)
        }
        if isSynthesizedDir(path) {
            return Self.dirMetadata
        }
        return try await backing.metadata(path)
    }

    public func list(_ path: String) async throws -> [String] {
        if isSynthesizedDir(path) {
            return synthesizedEntries(in: path)
        }
        return try await backing.list(path)
    }

    public func canonicalize(_ path: String,
                             allowMissing: Bool) async throws -> String {
        if isSynthesizedFile(path) || isSynthesizedDir(path) {
            return path
        }
        return try await backing.canonicalize(path, allowMissing: allowMissing)
    }

    // MARK: Reading

    public func readData(_ path: String) async throws -> Data {
        if isSynthesizedFile(path) {
            return Self.stubBytes(forCommand:
                (path as NSString).lastPathComponent)
        }
        if isSynthesizedDir(path) {
            throw FileSystemError.isADirectory(path)
        }
        return try await backing.readData(path)
    }

    public func openRead(_ path: String) async throws -> InputSource {
        if isSynthesizedFile(path) {
            return .data(try await readData(path))
        }
        return try await backing.openRead(path)
    }

    // MARK: Writing — synthesized files reject all writes

    public func writeData(_ data: Data, to path: String,
                          append: Bool) async throws
    {
        if isSynthesizedFile(path) || isSynthesizedDir(path) {
            throw FileSystemError.permissionDenied(path)
        }
        try await backing.writeData(data, to: path, append: append)
    }

    public func openWrite(_ path: String,
                          append: Bool) async throws -> OutputSink
    {
        if isSynthesizedFile(path) || isSynthesizedDir(path) {
            throw FileSystemError.permissionDenied(path)
        }
        return try await backing.openWrite(path, append: append)
    }

    public func touch(_ path: String) async throws {
        if isSynthesizedFile(path) || isSynthesizedDir(path) {
            throw FileSystemError.permissionDenied(path)
        }
        try await backing.touch(path)
    }

    // MARK: Directories

    public func createDirectory(_ path: String,
                                intermediates: Bool) async throws
    {
        if isSynthesizedDir(path) {
            throw FileSystemError.alreadyExists(path)
        }
        try await backing.createDirectory(path, intermediates: intermediates)
    }

    // MARK: Removal / move / copy

    public func remove(_ path: String, recursive: Bool) async throws {
        if isSynthesizedFile(path) || isSynthesizedDir(path) {
            throw FileSystemError.permissionDenied(path)
        }
        try await backing.remove(path, recursive: recursive)
    }

    public func move(from: String, to: String) async throws {
        if isSynthesizedFile(from) || isSynthesizedDir(from)
            || isSynthesizedFile(to) || isSynthesizedDir(to)
        {
            throw FileSystemError.permissionDenied(from)
        }
        try await backing.move(from: from, to: to)
    }

    public func copy(from: String, to: String) async throws {
        if isSynthesizedFile(to) || isSynthesizedDir(to) {
            throw FileSystemError.permissionDenied(to)
        }
        if isSynthesizedFile(from) {
            // Materialise the stub bytes into the backing fs.
            try await backing.writeData(
                try await readData(from), to: to, append: false)
            return
        }
        try await backing.copy(from: from, to: to)
    }

    public func makeTempPath(prefix: String) async throws -> String {
        try await backing.makeTempPath(prefix: prefix)
    }

    // MARK: Permissions / ownership / links / xattrs — pass-through
    // for non-synthesized paths, no-op-ish for synthesized.

    public func chmod(_ path: String, mode: UInt16) async throws {
        if isSynthesizedFile(path) || isSynthesizedDir(path) {
            throw FileSystemError.permissionDenied(path)
        }
        try await backing.chmod(path, mode: mode)
    }

    public func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
        if isSynthesizedFile(path) || isSynthesizedDir(path) {
            throw FileSystemError.permissionDenied(path)
        }
        try await backing.chown(path, uid: uid, gid: gid)
    }

    public func symlink(target: String, at linkPath: String) async throws {
        if isSynthesizedFile(linkPath) || isSynthesizedDir(linkPath) {
            throw FileSystemError.permissionDenied(linkPath)
        }
        try await backing.symlink(target: target, at: linkPath)
    }

    public func hardlink(target: String, at linkPath: String) async throws {
        if isSynthesizedFile(linkPath) || isSynthesizedDir(linkPath) {
            throw FileSystemError.permissionDenied(linkPath)
        }
        try await backing.hardlink(target: target, at: linkPath)
    }

    public func listXattrs(_ path: String) async throws -> [String] {
        if isSynthesizedFile(path) || isSynthesizedDir(path) { return [] }
        return try await backing.listXattrs(path)
    }

    public func getXattr(_ path: String, name: String) async throws -> Data {
        if isSynthesizedFile(path) || isSynthesizedDir(path) {
            throw FileSystemError.io("no such xattr: \(name)")
        }
        return try await backing.getXattr(path, name: name)
    }

    public func setXattr(_ path: String, name: String, value: Data) async throws {
        if isSynthesizedFile(path) || isSynthesizedDir(path) {
            throw FileSystemError.permissionDenied(path)
        }
        try await backing.setXattr(path, name: name, value: value)
    }

    public func removeXattr(_ path: String, name: String) async throws {
        if isSynthesizedFile(path) || isSynthesizedDir(path) { return }
        try await backing.removeXattr(path, name: name)
    }

    // MARK: Synthesized-file helpers

    /// Bytes returned when the script reads a synthesized binary —
    /// e.g. `cat /bin/cat`. Just a one-line marker, since the file
    /// has no real ELF / Mach-O contents.
    private static func stubBytes(forCommand name: String) -> Data {
        Data("swift-bash built-in command: \(name)\n".utf8)
    }

    /// Synthetic metadata for a `/bin/<name>` shadow file. Mode is
    /// `0o755`, owner / group come from the running shell's
    /// ``HostInfo`` so identity stays consistent with `whoami` / `id`.
    private static func fileMetadata(path: String) -> FileMetadata {
        let host = Shell.current.hostInfo
        let stub = stubBytes(forCommand: (path as NSString).lastPathComponent)
        // Use a fixed epoch-ish date so listings stay stable across runs.
        // Real macOS reports the install timestamp; we have no install
        // event, so any deterministic value works.
        let date = Date(timeIntervalSince1970: 0)
        return FileMetadata(
            kind: .file,
            size: Int64(stub.count),
            modifiedAt: date,
            mode: 0o755,
            uid: 0,
            gid: host.gid,
            linkCount: 1,
            accessedAt: date,
            createdAt: date)
    }

    /// Synthetic metadata for a synthesized directory (`/bin`,
    /// `/usr/bin`, `/usr/local/bin`).
    private static var dirMetadata: FileMetadata {
        let host = Shell.current.hostInfo
        let date = Date(timeIntervalSince1970: 0)
        return FileMetadata(
            kind: .directory,
            size: 0,
            modifiedAt: date,
            mode: 0o755,
            uid: 0,
            gid: host.gid,
            linkCount: 2,
            accessedAt: date,
            createdAt: date)
    }
}
