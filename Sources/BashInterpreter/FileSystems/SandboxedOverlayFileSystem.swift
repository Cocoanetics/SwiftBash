import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A copy-on-write ``FileSystem`` that confines a script to a single
/// host directory plus an in-memory ``/tmp`` scratch space.
///
/// Reads fall through to the real filesystem under ``Options/root``;
/// writes are captured in an in-memory layer and never touch disk.
/// Anything outside the configured mount point — including the host's
/// real `/etc`, `/Users`, `/private` — reports `ENOENT`.
///
/// ```swift
/// let fs = try SandboxedOverlayFileSystem(.init(
///     root: NSHomeDirectory() + "/Documents",
///     mountPoint: "/batch"))
/// var env = Environment.empty()
/// env.workingDirectory = "/batch"
/// let shell = Shell(environment: env, fileSystem: fs)
/// ```
///
/// Security model (mirrors the just-bash overlay):
/// - **Path confinement** — every host path passes through ``realpath(3)``
///   and is rejected if it escapes the canonical root.
/// - **Symlink guard** — when ``Options/allowSymlinks`` is `false`
///   (default), any host-side symlink causes the path to report as
///   missing. Detection compares the unresolved-vs-canonical relative
///   prefix and also `lstat`s the leaf to catch broken-symlink swaps.
/// - **TOCTOU closure** — the canonical path returned by `realpath` is
///   reused for every subsequent syscall, so a swap between validation
///   and use cannot redirect I/O.
/// - **Error sanitization** — every thrown `FileSystemError` references
///   the *virtual* path the caller supplied. Host paths are never
///   leaked, including in `NSError.localizedDescription`.
public final class SandboxedOverlayFileSystem: FileSystem, @unchecked Sendable {

    // MARK: Options

    public struct Options: Sendable {
        /// Host directory that backs the overlay. Must exist.
        public var root: String
        /// Virtual path where ``root`` appears. Default `"/batch"`.
        public var mountPoint: String
        /// If true, every write throws ``FileSystemError/permissionDenied(_:)``.
        public var readOnly: Bool
        /// Maximum byte count `readData` will return. Larger files
        /// throw. Set to 0 to disable. Default 10 MiB.
        public var maxFileReadSize: Int64
        /// Whether to follow host-side symlinks. When false, any
        /// symlink encountered on the host side reports as missing.
        public var allowSymlinks: Bool
        /// Provide an in-memory scratch directory at `/tmp`. Default true.
        public var includeTmpScratch: Bool

        public init(root: String,
                    mountPoint: String = "/batch",
                    readOnly: Bool = false,
                    maxFileReadSize: Int64 = 10 * 1024 * 1024,
                    allowSymlinks: Bool = false,
                    includeTmpScratch: Bool = true) {
            self.root = root
            self.mountPoint = mountPoint
            self.readOnly = readOnly
            self.maxFileReadSize = maxFileReadSize
            self.allowSymlinks = allowSymlinks
            self.includeTmpScratch = includeTmpScratch
        }
    }

    // MARK: Memory layer

    enum MemKind {
        case file(Data)
        case directory
        case symlink(target: String)
    }

    final class MemEntry {
        var kind: MemKind
        var mode: UInt16
        var uid: UInt32
        var gid: UInt32
        var mtime: Date
        var xattrs: [String: Data]
        init(kind: MemKind, mode: UInt16, mtime: Date = Date()) {
            self.kind = kind
            self.mode = mode
            self.uid = UInt32(getuid())
            self.gid = UInt32(getgid())
            self.mtime = mtime
            self.xattrs = [:]
        }
    }

    // MARK: State

    public let options: Options
    private let root: String           // absolute, no trailing /
    private let canonicalRoot: String
    private let mountPoint: String     // no trailing /, never "/"
    private let lock = NSLock()
    private var memory: [String: MemEntry] = [:]
    private var deleted: Set<String> = []

    // MARK: Init

    public init(_ options: Options) throws {
        self.options = options

        // Validate root.
        let normalizedRoot = (options.root as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(
                atPath: normalizedRoot, isDirectory: &isDir),
              isDir.boolValue
        else {
            throw FileSystemError.notFound(options.root)
        }
        self.root = normalizedRoot.hasSuffix("/") && normalizedRoot.count > 1
            ? String(normalizedRoot.dropLast()) : normalizedRoot
        self.canonicalRoot = Self.realpathOrSelf(self.root)

        // Validate + normalize mount point.
        guard options.mountPoint.hasPrefix("/") else {
            throw FileSystemError.io("mount point must be absolute")
        }
        var mp = options.mountPoint
        while mp.count > 1 && mp.hasSuffix("/") { mp.removeLast() }
        if mp == "/" {
            throw FileSystemError.io(
                "mount point must not be / (use a sub-path like /batch)")
        }
        self.mountPoint = mp

        seedDirectories()
    }

    /// Seed the memory layer with directory entries for `/`, the
    /// mount-point chain, and (optionally) `/tmp`. Without these,
    /// `cd /`, `cd /batch`, and `cd /tmp` would fail.
    private func seedDirectories() {
        memory["/"] = MemEntry(kind: .directory, mode: 0o755)
        var current = ""
        for part in mountPoint.split(separator: "/") {
            current += "/\(part)"
            if memory[current] == nil {
                memory[current] = MemEntry(kind: .directory, mode: 0o755)
            }
        }
        if options.includeTmpScratch {
            memory["/tmp"] = MemEntry(kind: .directory, mode: 0o1777)
        }
    }

    // MARK: FileSystem — inspection

    public func metadata(_ path: String) async throws -> FileMetadata? {
        let normalized = try Self.normalizePath(path)
        return lock.withLock {
            if deleted.contains(normalized) { return nil }
            if let mem = memory[normalized] { return Self.toMetadata(mem) }
            guard let canonical = resolveRealPath(forVirtual: normalized)
            else { return nil }
            return statMetadata(canonical)
        }
    }

    public func list(_ path: String) async throws -> [String] {
        let normalized = try Self.normalizePath(path)
        return try lock.withLock {
            if deleted.contains(normalized) {
                throw fsError(.notFound, virtualPath: path)
            }
            // Determine if this directory exists at all.
            var exists = false
            if let mem = memory[normalized] {
                if case .directory = mem.kind {
                    exists = true
                } else {
                    throw fsError(.notADirectory, virtualPath: path)
                }
            }
            // Collect host children (if mapped).
            var entries: Set<String> = []
            if let canonical = resolveRealPath(forVirtual: normalized) {
                exists = true
                if let real = try? FileManager.default
                    .contentsOfDirectory(atPath: canonical)
                {
                    for name in real { entries.insert(name) }
                }
            }
            if !exists {
                throw fsError(.notFound, virtualPath: path)
            }
            // Layer in memory children, then strip tombstones.
            let prefix = normalized == "/" ? "/" : normalized + "/"
            for (memPath, mem) in memory {
                guard memPath != normalized,
                      memPath.hasPrefix(prefix)
                else { continue }
                let rest = memPath.dropFirst(prefix.count)
                if rest.contains("/") { continue }
                // Memory entries always trump host entries — they may
                // override type or be wholly synthetic.
                _ = mem
                entries.insert(String(rest))
            }
            for tomb in deleted {
                guard tomb != normalized, tomb.hasPrefix(prefix) else { continue }
                let rest = tomb.dropFirst(prefix.count)
                if rest.contains("/") { continue }
                entries.remove(String(rest))
            }
            return Array(entries)
        }
    }

    public func canonicalize(_ path: String,
                             allowMissing: Bool) async throws -> String {
        let normalized = try Self.normalizePath(path)
        return try lock.withLock {
            if memory[normalized] != nil {
                if deleted.contains(normalized) {
                    if allowMissing { return normalized }
                    throw fsError(.notFound, virtualPath: path)
                }
                return normalized
            }
            if resolveRealPath(forVirtual: normalized) != nil {
                return normalized
            }
            if allowMissing { return normalized }
            throw fsError(.notFound, virtualPath: path)
        }
    }

    // MARK: FileSystem — read

    public func readData(_ path: String) async throws -> Data {
        let normalized = try Self.normalizePath(path)
        return try lock.withLock {
            if deleted.contains(normalized) {
                throw fsError(.notFound, virtualPath: path)
            }
            if let mem = memory[normalized] {
                switch mem.kind {
                case .file(let d): return d
                case .directory:
                    throw fsError(.isADirectory, virtualPath: path)
                case .symlink:
                    throw fsError(.notFound, virtualPath: path)
                }
            }
            guard let canonical = resolveRealPath(forVirtual: normalized)
            else { throw fsError(.notFound, virtualPath: path) }
            // Reject directories explicitly to mirror POSIX `read(2)` on dirs.
            if let st = lstatStruct(canonical),
               (st.st_mode & S_IFMT) == S_IFDIR
            {
                throw fsError(.isADirectory, virtualPath: path)
            }
            // Bound the read.
            if options.maxFileReadSize > 0,
               let st = lstatStruct(canonical),
               st.st_size > options.maxFileReadSize
            {
                throw fsError(.io("file too large"), virtualPath: path)
            }
            // O_NOFOLLOW guards against a symlink swap between resolve
            // and open when symlinks are disabled.
            let flags = options.allowSymlinks ? O_RDONLY : (O_RDONLY | O_NOFOLLOW)
            let fd = canonical.withCString { open($0, flags) }
            if fd < 0 { throw fsError(.notFound, virtualPath: path) }
            defer { close(fd) }
            return readAll(fd: fd)
        }
    }

    // MARK: FileSystem — write

    public func writeData(_ data: Data, to path: String,
                          append: Bool) async throws
    {
        let normalized = try Self.normalizePath(path)
        try lock.withLock {
            try assertWritable(virtualPath: path)
            try ensureParentExists(of: normalized, virtualPath: path)
            // Rejecting directory overwrite.
            if let mem = memory[normalized],
               case .directory = mem.kind
            {
                throw fsError(.isADirectory, virtualPath: path)
            }
            var combined = Data()
            if append {
                if let mem = memory[normalized],
                   case .file(let existing) = mem.kind
                {
                    combined = existing
                } else if !deleted.contains(normalized),
                          let canonical = resolveRealPath(forVirtual: normalized),
                          let host = try? Data(contentsOf:
                            URL(fileURLWithPath: canonical))
                {
                    combined = host
                }
            }
            combined.append(data)
            memory[normalized] = MemEntry(
                kind: .file(combined), mode: 0o644)
            deleted.remove(normalized)
        }
    }

    public func touch(_ path: String) async throws {
        let normalized = try Self.normalizePath(path)
        try lock.withLock {
            try assertWritable(virtualPath: path)
            try ensureParentExists(of: normalized, virtualPath: path)
            if let mem = memory[normalized] {
                mem.mtime = Date()
                return
            }
            if !deleted.contains(normalized),
               let canonical = resolveRealPath(forVirtual: normalized)
            {
                // Promote the host file into memory (with current contents)
                // so we can update mtime without writing to disk.
                let data = (try? Data(contentsOf:
                    URL(fileURLWithPath: canonical))) ?? Data()
                memory[normalized] = MemEntry(
                    kind: .file(data), mode: 0o644)
                return
            }
            memory[normalized] = MemEntry(kind: .file(Data()), mode: 0o644)
            deleted.remove(normalized)
        }
    }

    // MARK: FileSystem — directories

    public func createDirectory(_ path: String,
                                intermediates: Bool) async throws
    {
        let normalized = try Self.normalizePath(path)
        try lock.withLock {
            try assertWritable(virtualPath: path)
            if normalized == "/" {
                throw fsError(.alreadyExists, virtualPath: path)
            }
            if intermediates {
                try createDirectoryChain(normalized, virtualPath: path)
                return
            }
            try ensureParentExists(of: normalized, virtualPath: path)
            if existsLocked(normalized) {
                throw fsError(.alreadyExists, virtualPath: path)
            }
            memory[normalized] = MemEntry(kind: .directory, mode: 0o755)
            deleted.remove(normalized)
        }
    }

    private func createDirectoryChain(_ path: String,
                                      virtualPath: String) throws
    {
        var current = ""
        for part in path.split(separator: "/") {
            current += "/\(part)"
            if existsLocked(current) {
                if let mem = memory[current],
                   case .directory = mem.kind
                {
                    continue
                }
                if let canonical = resolveRealPath(forVirtual: current),
                   let st = lstatStruct(canonical),
                   (st.st_mode & S_IFMT) == S_IFDIR
                {
                    continue
                }
                throw fsError(.notADirectory, virtualPath: virtualPath)
            }
            memory[current] = MemEntry(kind: .directory, mode: 0o755)
            deleted.remove(current)
        }
    }

    // MARK: FileSystem — remove / move / copy

    public func remove(_ path: String, recursive: Bool) async throws {
        let normalized = try Self.normalizePath(path)
        try lock.withLock {
            try assertWritable(virtualPath: path)
            guard existsLocked(normalized) else {
                throw fsError(.notFound, virtualPath: path)
            }
            // Directory-with-children needs recursive.
            if isDirectoryLocked(normalized) {
                let children = try listLocked(normalized, virtualPath: path)
                if !children.isEmpty {
                    if !recursive {
                        throw fsError(.isADirectory, virtualPath: path)
                    }
                    for child in children {
                        let childPath = normalized == "/"
                            ? "/\(child)" : "\(normalized)/\(child)"
                        try removeLocked(childPath,
                                         virtualPath: childPath,
                                         recursive: true)
                    }
                }
            }
            try removeLocked(normalized,
                             virtualPath: path,
                             recursive: recursive)
        }
    }

    private func removeLocked(_ normalized: String,
                              virtualPath: String,
                              recursive: Bool) throws
    {
        // Remove from memory; if the path also exists on host, plant a
        // tombstone so subsequent reads see it as gone.
        memory.removeValue(forKey: normalized)
        if resolveRealPath(forVirtual: normalized) != nil {
            deleted.insert(normalized)
        }
    }

    public func move(from: String, to: String) async throws {
        let src = try Self.normalizePath(from)
        let dst = try Self.normalizePath(to)
        try lock.withLock {
            try assertWritable(virtualPath: to)
            guard existsLocked(src) else {
                throw fsError(.notFound, virtualPath: from)
            }
            if existsLocked(dst) {
                throw fsError(.alreadyExists, virtualPath: to)
            }
            try ensureParentExists(of: dst, virtualPath: to)
            try copyLocked(src: src, srcVirtual: from,
                           dst: dst, dstVirtual: to)
            try removeLocked(src, virtualPath: from, recursive: true)
        }
    }

    public func copy(from: String, to: String) async throws {
        let src = try Self.normalizePath(from)
        let dst = try Self.normalizePath(to)
        try lock.withLock {
            try assertWritable(virtualPath: to)
            guard existsLocked(src) else {
                throw fsError(.notFound, virtualPath: from)
            }
            if existsLocked(dst) {
                throw fsError(.alreadyExists, virtualPath: to)
            }
            try ensureParentExists(of: dst, virtualPath: to)
            try copyLocked(src: src, srcVirtual: from,
                           dst: dst, dstVirtual: to)
        }
    }

    private func copyLocked(src: String, srcVirtual: String,
                            dst: String, dstVirtual: String) throws
    {
        if isDirectoryLocked(src) {
            memory[dst] = MemEntry(kind: .directory, mode: 0o755)
            deleted.remove(dst)
            let children = try listLocked(src, virtualPath: srcVirtual)
            for child in children {
                let s = src == "/" ? "/\(child)" : "\(src)/\(child)"
                let d = dst == "/" ? "/\(child)" : "\(dst)/\(child)"
                try copyLocked(src: s, srcVirtual: s, dst: d, dstVirtual: d)
            }
            return
        }
        // File copy: read through (memory or host) then plant in memory.
        let data: Data
        if let mem = memory[src], case .file(let d) = mem.kind {
            data = d
        } else if let canonical = resolveRealPath(forVirtual: src) {
            data = (try? Data(contentsOf: URL(fileURLWithPath: canonical)))
                   ?? Data()
        } else {
            throw fsError(.notFound, virtualPath: srcVirtual)
        }
        memory[dst] = MemEntry(kind: .file(data), mode: 0o644)
        deleted.remove(dst)
    }

    public func makeTempPath(prefix: String) async throws -> String {
        // Inside the sandbox, /tmp is the in-memory scratch dir.
        let dir = options.includeTmpScratch ? "/tmp" : mountPoint
        return "\(dir)/\(prefix)-\(UUID().uuidString)"
    }

    // MARK: FileSystem — permissions / xattrs / links

    public func chmod(_ path: String, mode: UInt16) async throws {
        let normalized = try Self.normalizePath(path)
        try lock.withLock {
            try assertWritable(virtualPath: path)
            try promoteToMemoryIfNeeded(normalized, virtualPath: path)
            memory[normalized]?.mode = mode & 0o7777
        }
    }

    public func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
        let normalized = try Self.normalizePath(path)
        try lock.withLock {
            try assertWritable(virtualPath: path)
            try promoteToMemoryIfNeeded(normalized, virtualPath: path)
            if let u = uid { memory[normalized]?.uid = u }
            if let g = gid { memory[normalized]?.gid = g }
        }
    }

    public func symlink(target: String, at linkPath: String) async throws {
        let normalized = try Self.normalizePath(linkPath)
        try lock.withLock {
            try assertWritable(virtualPath: linkPath)
            if !options.allowSymlinks {
                throw fsError(.permissionDenied, virtualPath: linkPath)
            }
            if existsLocked(normalized) {
                throw fsError(.alreadyExists, virtualPath: linkPath)
            }
            try ensureParentExists(of: normalized, virtualPath: linkPath)
            memory[normalized] = MemEntry(
                kind: .symlink(target: target), mode: 0o777)
            deleted.remove(normalized)
        }
    }

    public func hardlink(target: String, at linkPath: String) async throws {
        // Hardlinks would share an inode with a host file, which we
        // cannot honour without writing to the host. Fall back to copy.
        try await copy(from: target, to: linkPath)
    }

    public func listXattrs(_ path: String) async throws -> [String] {
        let normalized = try Self.normalizePath(path)
        return try lock.withLock {
            try promoteToMemoryIfNeeded(normalized, virtualPath: path)
            let xattrs = memory[normalized]?.xattrs ?? [:]
            return xattrs.keys.sorted()
        }
    }

    public func getXattr(_ path: String, name: String) async throws -> Data {
        let normalized = try Self.normalizePath(path)
        return try lock.withLock {
            try promoteToMemoryIfNeeded(normalized, virtualPath: path)
            guard let v = memory[normalized]?.xattrs[name] else {
                throw fsError(.io("no such xattr: \(name)"),
                              virtualPath: path)
            }
            return v
        }
    }

    public func setXattr(_ path: String, name: String, value: Data) async throws {
        let normalized = try Self.normalizePath(path)
        try lock.withLock {
            try assertWritable(virtualPath: path)
            try promoteToMemoryIfNeeded(normalized, virtualPath: path)
            memory[normalized]?.xattrs[name] = value
        }
    }

    public func removeXattr(_ path: String, name: String) async throws {
        let normalized = try Self.normalizePath(path)
        try lock.withLock {
            try assertWritable(virtualPath: path)
            try promoteToMemoryIfNeeded(normalized, virtualPath: path)
            memory[normalized]?.xattrs.removeValue(forKey: name)
        }
    }

    // MARK: Internals — write helpers (lock held)

    private func assertWritable(virtualPath: String) throws {
        if options.readOnly {
            throw fsError(.permissionDenied, virtualPath: virtualPath)
        }
    }

    private func ensureParentExists(of normalized: String,
                                    virtualPath: String) throws
    {
        guard normalized != "/" else { return }
        let parent = (normalized as NSString).deletingLastPathComponent
        let parentClean = parent.isEmpty ? "/" : parent
        guard existsLocked(parentClean) else {
            throw fsError(.notFound, virtualPath: virtualPath)
        }
        if !isDirectoryLocked(parentClean) {
            throw fsError(.notADirectory, virtualPath: virtualPath)
        }
    }

    private func promoteToMemoryIfNeeded(_ normalized: String,
                                         virtualPath: String) throws
    {
        if memory[normalized] != nil { return }
        if deleted.contains(normalized) {
            throw fsError(.notFound, virtualPath: virtualPath)
        }
        guard let canonical = resolveRealPath(forVirtual: normalized) else {
            throw fsError(.notFound, virtualPath: virtualPath)
        }
        guard let st = lstatStruct(canonical) else {
            throw fsError(.notFound, virtualPath: virtualPath)
        }
        let kind: MemKind
        if (st.st_mode & S_IFMT) == S_IFDIR {
            kind = .directory
        } else {
            let data = (try? Data(contentsOf:
                URL(fileURLWithPath: canonical))) ?? Data()
            kind = .file(data)
        }
        memory[normalized] = MemEntry(
            kind: kind, mode: UInt16(st.st_mode & 0o7777))
    }

    // MARK: Internals — existence (lock held)

    private func existsLocked(_ normalized: String) -> Bool {
        if deleted.contains(normalized) { return false }
        if memory[normalized] != nil { return true }
        return resolveRealPath(forVirtual: normalized) != nil
    }

    private func isDirectoryLocked(_ normalized: String) -> Bool {
        if let mem = memory[normalized] {
            if case .directory = mem.kind { return true }
            return false
        }
        guard let canonical = resolveRealPath(forVirtual: normalized),
              let st = lstatStruct(canonical)
        else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    private func listLocked(_ normalized: String,
                            virtualPath: String) throws -> [String]
    {
        var entries: Set<String> = []
        if let canonical = resolveRealPath(forVirtual: normalized),
           let real = try? FileManager.default
            .contentsOfDirectory(atPath: canonical)
        {
            for n in real { entries.insert(n) }
        }
        let prefix = normalized == "/" ? "/" : normalized + "/"
        for memPath in memory.keys {
            guard memPath != normalized, memPath.hasPrefix(prefix) else { continue }
            let rest = memPath.dropFirst(prefix.count)
            if rest.contains("/") { continue }
            entries.insert(String(rest))
        }
        for tomb in deleted {
            guard tomb != normalized, tomb.hasPrefix(prefix) else { continue }
            let rest = tomb.dropFirst(prefix.count)
            if rest.contains("/") { continue }
            entries.remove(String(rest))
        }
        return Array(entries)
    }

    // MARK: Internals — host path mapping (lock held)

    /// Translate a virtual path under the mount point into a host path
    /// that is guaranteed to stay inside ``canonicalRoot`` and (when
    /// symlinks are disabled) does not traverse any host-side symlink.
    /// Returns `nil` for paths outside the mount point or that fail
    /// any check.
    private func resolveRealPath(forVirtual virtualPath: String) -> String? {
        guard let real = toRealPath(virtualPath) else { return nil }
        return resolveRealPath(real)
    }

    private func toRealPath(_ virtualPath: String) -> String? {
        let rel: String
        if virtualPath == mountPoint {
            rel = ""
        } else if virtualPath.hasPrefix(mountPoint + "/") {
            rel = String(virtualPath.dropFirst(mountPoint.count))
        } else {
            return nil
        }
        // Lexical confinement before any syscall.
        let candidate = root + rel
        let standardized = (candidate as NSString).standardizingPath
        guard Self.isPathWithinRoot(standardized, root: root) else {
            return nil
        }
        return standardized
    }

    /// Resolve via realpath(3), enforce sandbox confinement, and (when
    /// symlinks are disabled) reject any path that crossed a symlink.
    /// Returns `nil` if the path doesn't exist on the host — broken
    /// symlinks therefore look like missing paths to the sandbox, which
    /// is the safe answer.
    private func resolveRealPath(_ realPath: String) -> String? {
        guard let canon = Self.realpath(realPath) else { return nil }
        guard Self.isPathWithinRoot(canon, root: canonicalRoot)
        else { return nil }
        if !options.allowSymlinks {
            let relUnresolved = String(realPath.dropFirst(root.count))
            let relCanon = String(canon.dropFirst(canonicalRoot.count))
            if relUnresolved != relCanon { return nil }
            if let st = lstatStruct(realPath),
               (st.st_mode & S_IFMT) == S_IFLNK
            {
                return nil
            }
        }
        return canon
    }

    // MARK: Internals — metadata adapters

    private static func toMetadata(_ entry: MemEntry) -> FileMetadata {
        switch entry.kind {
        case .file(let d):
            return FileMetadata(kind: .file,
                                size: Int64(d.count),
                                modifiedAt: entry.mtime,
                                mode: entry.mode,
                                uid: entry.uid,
                                gid: entry.gid)
        case .directory:
            return FileMetadata(kind: .directory,
                                size: 0,
                                modifiedAt: entry.mtime,
                                mode: entry.mode,
                                uid: entry.uid,
                                gid: entry.gid)
        case .symlink(let t):
            return FileMetadata(kind: .symlink,
                                size: Int64(t.utf8.count),
                                modifiedAt: entry.mtime,
                                symlinkTarget: t,
                                mode: entry.mode,
                                uid: entry.uid,
                                gid: entry.gid)
        }
    }

    /// Return follow-symlinks metadata for a host path. Returns `nil`
    /// if the path doesn't exist; symlinks are reported with a `nil`
    /// `symlinkTarget` here because host symlinks were already either
    /// rejected (when off) or transparently followed by `fstatat`.
    private func statMetadata(_ canonical: String) -> FileMetadata? {
        var st = stat()
        guard canonical.withCString({ fstatat(AT_FDCWD, $0, &st, 0) }) == 0
        else { return nil }
        let kind: FileMetadata.Kind
        switch st.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return FileMetadata(
            kind: kind,
            size: Int64(st.st_size),
            modifiedAt: Date(timeIntervalSince1970:
                                TimeInterval(st.st_mtimespec.tv_sec)),
            mode: UInt16(st.st_mode & 0o7777),
            uid: UInt32(st.st_uid),
            gid: UInt32(st.st_gid),
            linkCount: Int(st.st_nlink))
    }

    // MARK: Internals — error construction

    private enum ErrorKind {
        case notFound, notADirectory, isADirectory
        case alreadyExists, permissionDenied
        case io(String)
    }

    /// Build a ``FileSystemError`` using the *virtual* path the caller
    /// supplied, never the host path. Callers should never propagate
    /// raw `NSError.localizedDescription` strings to the script.
    private func fsError(_ kind: ErrorKind,
                         virtualPath: String) -> FileSystemError {
        switch kind {
        case .notFound:         return .notFound(virtualPath)
        case .notADirectory:    return .notADirectory(virtualPath)
        case .isADirectory:     return .isADirectory(virtualPath)
        case .alreadyExists:    return .alreadyExists(virtualPath)
        case .permissionDenied: return .permissionDenied(virtualPath)
        case .io(let msg):      return .io("\(msg): \(virtualPath)")
        }
    }

    // MARK: Static helpers

    /// Reject paths that contain NUL bytes; collapse `.` and `..`.
    static func normalizePath(_ path: String) throws -> String {
        if path.contains("\0") {
            throw FileSystemError.io("invalid path: NUL byte")
        }
        var stack: [String] = []
        for seg in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch seg {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(String(seg))
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    static func isPathWithinRoot(_ path: String, root: String) -> Bool {
        if path == root { return true }
        guard path.hasPrefix(root) else { return false }
        let next = path.index(path.startIndex, offsetBy: root.count)
        return path[next] == "/"
    }

    /// Wrapper over POSIX `realpath(3)`. Returns `nil` on failure
    /// (typically `ENOENT`).
    static func realpath(_ path: String) -> String? {
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
        let ok = path.withCString { p -> Bool in
            buf.withUnsafeMutableBufferPointer { bp in
                Darwin.realpath(p, bp.baseAddress) != nil
            }
        }
        if !ok { return nil }
        let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `realpath` falling back to the input on failure. Used only at
    /// init time for the sandbox root.
    static func realpathOrSelf(_ path: String) -> String {
        realpath(path) ?? path
    }
}

// MARK: - Tiny POSIX helpers

private func lstatStruct(_ path: String) -> stat? {
    var st = stat()
    let r = path.withCString { lstat($0, &st) }
    return r == 0 ? st : nil
}

private func readAll(fd: Int32) -> Data {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = buf.withUnsafeMutableBufferPointer { bp in
            read(fd, bp.baseAddress, bp.count)
        }
        if n <= 0 { break }
        data.append(buf, count: n)
    }
    return data
}
