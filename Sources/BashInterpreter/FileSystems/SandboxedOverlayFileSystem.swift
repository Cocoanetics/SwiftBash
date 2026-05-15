import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

// A copy-on-write ``FileSystem`` that confines a script to a single
// host directory plus an in-memory ``/tmp`` scratch space.
//
// Reads fall through to the real filesystem under ``Options/root``;
// writes are captured in an in-memory layer and never touch disk.
// Anything outside the configured mount point — including the host's
// real `/etc`, `/Users`, `/private` — reports `ENOENT`.
//
// ```swift
// let fs = try SandboxedOverlayFileSystem(.init(
//     root: NSHomeDirectory() + "/Documents",
//     mountPoint: "/batch"))
// var env = Environment.empty()
// env.workingDirectory = "/batch"
// let shell = Shell(environment: env, fileSystem: fs)
// ```
//
// Security model (mirrors the just-bash overlay):
// - **Path confinement** — every host path passes through ``realpath(3)``
//   and is rejected if it escapes the canonical root.
// - **Symlink guard** — when ``Options/allowSymlinks`` is `false`
//   (default), any host-side symlink causes the path to report as
//   missing. Detection compares the unresolved-vs-canonical relative
//   prefix and also `lstat`s the leaf to catch broken-symlink swaps.
// - **TOCTOU closure** — the canonical path returned by `realpath` is
//   reused for every subsequent syscall, so a swap between validation
//   and use cannot redirect I/O.
// - Error sanitization: every thrown FileSystemError references
//   the virtual path the caller supplied. Host paths are never
//   leaked, including in NSError.localizedDescription.
// swiftlint:disable:next type_body_length - sandbox class is cohesive
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
        init(kind: MemKind, mode: UInt16, mtime: Date = Date(),
             uid: UInt32 = 1000, gid: UInt32 = 1000) {
            self.kind = kind
            self.mode = mode
            // Default owner matches `HostInfo.synthetic`. Never call
            // `getuid()` / `getgid()` here — doing so would leak the
            // host's real uid through `stat` even when the rest of the
            // shell reports synthetic identity.
            self.uid = uid
            self.gid = gid
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
        var mountPath = options.mountPoint
        while mountPath.count > 1 && mountPath.hasSuffix("/") { mountPath.removeLast() }
        if mountPath == "/" {
            throw FileSystemError.io(
                "mount point must not be / (use a sub-path like /batch)")
        }
        self.mountPoint = mountPath

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

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func list(_ path: String) async throws -> [FileEntry] {
        let normalized = try Self.normalizePath(path)
        let names: [String] = try lock.withLock {
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
            // Collect host children (if mapped). Filter out any child
            // whose own resolution would fail the sandbox confinement
            // or symlink-guard checks — otherwise a host-side symlink
            // pointing outside the root would be visible by name in
            // `ls` even though `cat` / `stat` on it report missing.
            // Listing must agree with reachability.
            var entries: Set<String> = []
            if let canonical = resolveRealPath(forVirtual: normalized) {
                exists = true
                if let real = try? FileManager.default
                    .contentsOfDirectory(atPath: canonical) {
                    let childPrefix = normalized == "/"
                        ? "/" : normalized + "/"
                    for name in real {
                        // Skip "." / ".." defensively; FileManager
                        // doesn't return them but be explicit.
                        if name == "." || name == ".." { continue }
                        let virtualChild = childPrefix + name
                        if resolveRealPath(forVirtual: virtualChild) != nil {
                            entries.insert(name)
                        }
                    }
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
        // Stat each child outside the lock. Drop entries we can't
        // resolve (race with delete, host symlink swap, etc.) so
        // listings agree with reachability.
        let childPrefix = normalized == "/" ? "/" : normalized + "/"
        var result: [FileEntry] = []
        result.reserveCapacity(names.count)
        for name in names {
            if let meta = try? await metadata(childPrefix + name) {
                result.append(FileEntry(name: name, metadata: meta))
            }
        }
        return result
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
                case .file(let data): return data
                case .directory:
                    throw fsError(.isADirectory, virtualPath: path)
                case .symlink:
                    throw fsError(.notFound, virtualPath: path)
                }
            }
            guard let canonical = resolveRealPath(forVirtual: normalized)
            else { throw fsError(.notFound, virtualPath: path) }
            // Reject directories explicitly to mirror POSIX `read(2)` on dirs.
            if let stat = lstatStruct(canonical), stat.isDirectory {
                throw fsError(.isADirectory, virtualPath: path)
            }
            // Bound the read.
            if options.maxFileReadSize > 0,
               let stat = lstatStruct(canonical),
               stat.size > options.maxFileReadSize {
                throw fsError(.ioError("file too large"), virtualPath: path)
            }
            return try readConfined(canonical: canonical, virtualPath: path)
        }
    }

    /// Read the resolved canonical path, defeating a TOCTOU symlink
    /// swap when symlinks are disabled. POSIX uses `O_NOFOLLOW`;
    /// Windows checks for `FILE_ATTRIBUTE_REPARSE_POINT` instead.
    private func readConfined(canonical: String,
                              virtualPath: String) throws -> Data {
        #if os(Windows)
        if !options.allowSymlinks {
            let attrs = canonical.withCString(encodedAs: UTF16.self) { widePath in
                GetFileAttributesW(widePath)
            }
            if attrs != INVALID_FILE_ATTRIBUTES,
               (attrs & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) != 0 {
                throw fsError(.notFound, virtualPath: virtualPath)
            }
        }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: canonical))
        } catch let nsErr as NSError where nsErr.code == NSFileReadNoSuchFileError {
            throw fsError(.notFound, virtualPath: virtualPath)
        } catch let nsErr as NSError where nsErr.code == NSFileReadNoPermissionError {
            throw fsError(.permissionDenied, virtualPath: virtualPath)
        } catch {
            throw fsError(.notFound, virtualPath: virtualPath)
        }
        #else
        // O_NOFOLLOW guards against a symlink swap between resolve
        // and open when symlinks are disabled.
        let flags = options.allowSymlinks ? O_RDONLY : (O_RDONLY | O_NOFOLLOW)
        let fileDesc = canonical.withCString { open($0, flags) }
        if fileDesc < 0 { throw fsError(.notFound, virtualPath: virtualPath) }
        defer { close(fileDesc) }
        return readAll(fd: fileDesc)
        #endif
    }

    // MARK: FileSystem — write

    public func writeData(_ data: Data, to path: String,
                          append: Bool) async throws {
        let normalized = try Self.normalizePath(path)
        try lock.withLock {
            try assertWritable(virtualPath: path)
            try ensureParentExists(of: normalized, virtualPath: path)
            // Rejecting directory overwrite.
            if let mem = memory[normalized],
               case .directory = mem.kind {
                throw fsError(.isADirectory, virtualPath: path)
            }
            var combined = Data()
            if append {
                if let mem = memory[normalized],
                   case .file(let existing) = mem.kind {
                    combined = existing
                } else if !deleted.contains(normalized),
                          let canonical = resolveRealPath(forVirtual: normalized),
                          let host = try? Data(contentsOf:
                            URL(fileURLWithPath: canonical)) {
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
               let canonical = resolveRealPath(forVirtual: normalized) {
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
                                intermediates: Bool) async throws {
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
                                      virtualPath: String) throws {
        var current = ""
        for part in path.split(separator: "/") {
            current += "/\(part)"
            if existsLocked(current) {
                if let mem = memory[current],
                   case .directory = mem.kind {
                    continue
                }
                if let canonical = resolveRealPath(forVirtual: current),
                   let stat = lstatStruct(canonical), stat.isDirectory {
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
                              recursive: Bool) throws {
        // Remove from memory; if the path also exists on host, plant a
        // tombstone so subsequent reads see it as gone.
        memory.removeValue(forKey: normalized)
        if resolveRealPath(forVirtual: normalized) != nil {
            deleted.insert(normalized)
        }
    }

    public func move(from source: String, to destination: String) async throws {
        let src = try Self.normalizePath(source)
        let dst = try Self.normalizePath(destination)
        try lock.withLock {
            try assertWritable(virtualPath: destination)
            guard existsLocked(src) else {
                throw fsError(.notFound, virtualPath: source)
            }
            if existsLocked(dst) {
                throw fsError(.alreadyExists, virtualPath: destination)
            }
            try ensureParentExists(of: dst, virtualPath: destination)
            try copyLocked(src: src, srcVirtual: source,
                           dst: dst, dstVirtual: destination)
            try removeLocked(src, virtualPath: source, recursive: true)
        }
    }

    public func copy(from source: String, to destination: String) async throws {
        let src = try Self.normalizePath(source)
        let dst = try Self.normalizePath(destination)
        try lock.withLock {
            try assertWritable(virtualPath: destination)
            guard existsLocked(src) else {
                throw fsError(.notFound, virtualPath: source)
            }
            if existsLocked(dst) {
                throw fsError(.alreadyExists, virtualPath: destination)
            }
            try ensureParentExists(of: dst, virtualPath: destination)
            try copyLocked(src: src, srcVirtual: source,
                           dst: dst, dstVirtual: destination)
        }
    }

    private func copyLocked(src: String, srcVirtual: String,
                            dst: String, dstVirtual: String) throws {
        if isDirectoryLocked(src) {
            memory[dst] = MemEntry(kind: .directory, mode: 0o755)
            deleted.remove(dst)
            let children = try listLocked(src, virtualPath: srcVirtual)
            for child in children {
                let srcChild = src == "/" ? "/\(child)" : "\(src)/\(child)"
                let dstChild = dst == "/" ? "/\(child)" : "\(dst)/\(child)"
                try copyLocked(src: srcChild, srcVirtual: srcChild,
                               dst: dstChild, dstVirtual: dstChild)
            }
            return
        }
        // File copy: read through (memory or host) then plant in memory.
        let data: Data
        if let mem = memory[src], case .file(let fileData) = mem.kind {
            data = fileData
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
            if let newUID = uid { memory[normalized]?.uid = newUID }
            if let newGID = gid { memory[normalized]?.gid = newGID }
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
            guard let value = memory[normalized]?.xattrs[name] else {
                throw fsError(.ioError("no such xattr: \(name)"),
                              virtualPath: path)
            }
            return value
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
                                    virtualPath: String) throws {
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
                                         virtualPath: String) throws {
        if memory[normalized] != nil { return }
        if deleted.contains(normalized) {
            throw fsError(.notFound, virtualPath: virtualPath)
        }
        guard let canonical = resolveRealPath(forVirtual: normalized) else {
            throw fsError(.notFound, virtualPath: virtualPath)
        }
        guard let stat = lstatStruct(canonical) else {
            throw fsError(.notFound, virtualPath: virtualPath)
        }
        let kind: MemKind
        if stat.isDirectory {
            kind = .directory
        } else {
            let data = (try? Data(contentsOf:
                URL(fileURLWithPath: canonical))) ?? Data()
            kind = .file(data)
        }
        memory[normalized] = MemEntry(kind: kind, mode: stat.mode)
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
              let stat = lstatStruct(canonical)
        else { return false }
        return stat.isDirectory
    }

    private func listLocked(_ normalized: String,
                            virtualPath: String) throws -> [String] {
        var entries: Set<String> = []
        if let canonical = resolveRealPath(forVirtual: normalized),
           let real = try? FileManager.default
            .contentsOfDirectory(atPath: canonical) {
            for name in real { entries.insert(name) }
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
            if let stat = lstatStruct(realPath), stat.isSymlink {
                return nil
            }
        }
        return canon
    }

    // MARK: Internals — metadata adapters

    private static func toMetadata(_ entry: MemEntry) -> FileMetadata {
        switch entry.kind {
        case .file(let data):
            return FileMetadata(kind: .file,
                                size: Int64(data.count),
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
        case .symlink(let target):
            return FileMetadata(kind: .symlink,
                                size: Int64(target.utf8.count),
                                modifiedAt: entry.mtime,
                                symlinkTarget: target,
                                mode: entry.mode,
                                uid: entry.uid,
                                gid: entry.gid)
        }
    }

    /// Return follow-symlinks metadata for a host path. Returns `nil`
    /// if the path doesn't exist; symlinks are reported with a `nil`
    /// `symlinkTarget` here because host symlinks were already either
    /// rejected (when off) or transparently followed.
    private func statMetadata(_ canonical: String) -> FileMetadata? {
        #if os(Windows)
        return RealFileSystem.windowsMetadata(canonical)
        #else
        var statBuf = stat()
        guard canonical.withCString({ fstatat(AT_FDCWD, $0, &statBuf, 0) }) == 0
        else { return nil }
        let kind: FileMetadata.Kind
        switch statBuf.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        // Linux's `struct stat` spells the timespec field `st_mtim`
        // (no `spec` suffix); Darwin uses `st_mtimespec`. Equivalent.
        #if canImport(Darwin)
        let mtimeSec = TimeInterval(statBuf.st_mtimespec.tv_sec)
        #else
        let mtimeSec = TimeInterval(statBuf.st_mtim.tv_sec)
        #endif
        return FileMetadata(
            kind: kind,
            size: Int64(statBuf.st_size),
            modifiedAt: Date(timeIntervalSince1970: mtimeSec),
            mode: UInt16(statBuf.st_mode & 0o7777),
            uid: UInt32(statBuf.st_uid),
            gid: UInt32(statBuf.st_gid),
            linkCount: Int(statBuf.st_nlink))
        #endif
    }

    // MARK: Internals — error construction

    private enum ErrorKind {
        case notFound, notADirectory, isADirectory
        case alreadyExists, permissionDenied
        case ioError(String)
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
        case .ioError(let msg): return .io("\(msg): \(virtualPath)")
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

    /// Wrapper over POSIX `realpath(3)` (Windows: `GetFinalPathNameByHandleW`).
    /// Returns `nil` on failure (typically `ENOENT`).
    static func realpath(_ path: String) -> String? {
        #if os(Windows)
        let handle = path.withCString(encodedAs: UTF16.self) { widePath in
            CreateFileW(widePath,
                        0,
                        DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                        nil,
                        DWORD(OPEN_EXISTING),
                        DWORD(FILE_FLAG_BACKUP_SEMANTICS),
                        nil)
        }
        if handle == INVALID_HANDLE_VALUE { return nil }
        defer { CloseHandle(handle) }
        var buf = [WCHAR](repeating: 0, count: 32768)
        let count = buf.withUnsafeMutableBufferPointer { bufPtr in
            GetFinalPathNameByHandleW(handle, bufPtr.baseAddress, DWORD(bufPtr.count), 0)
        }
        if count == 0 || Int(count) >= buf.count { return nil }
        let str = String(decoding: buf.prefix(Int(count)), as: UTF16.self)
        // Strip the `\\?\` prefix and normalize to forward slashes so
        // the rest of the sandbox's path math (which assumes `/`) works.
        var stripped = str
        if stripped.hasPrefix(#"\\?\"#) {
            stripped = String(stripped.dropFirst(4))
        }
        return stripped.replacingOccurrences(of: #"\"#, with: "/")
        #else
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
        let success = path.withCString { cString -> Bool in
            buf.withUnsafeMutableBufferPointer { bufPtr in
                // POSIX realpath: was `Darwin.realpath` (Darwin
                // qualifier doesn't compile on Linux). Unqualified
                // resolves through whichever libc was imported.
                #if canImport(Darwin)
                return Darwin.realpath(cString, bufPtr.baseAddress) != nil
                #elseif canImport(Android)
                return Android.realpath(cString, bufPtr.baseAddress) != nil
                #elseif canImport(Bionic)
                return Bionic.realpath(cString, bufPtr.baseAddress) != nil
                #else
                return Glibc.realpath(cString, bufPtr.baseAddress) != nil
                #endif
            }
        }
        if !success { return nil }
        let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        // swiftlint:disable:next optional_data_string_conversion - realpath bytes are host-encoded
        return String(decoding: bytes, as: UTF8.self)
        #endif
    }

    /// `realpath` falling back to the input on failure. Used only at
    /// init time for the sandbox root.
    static func realpathOrSelf(_ path: String) -> String {
        realpath(path) ?? path
    }
}

// MARK: - Portable lstat shim

/// Portable subset of the POSIX `struct stat` fields the sandbox uses.
/// Built from `lstat` on POSIX and from `GetFileAttributesExW` (plus
/// `BY_HANDLE_FILE_INFORMATION` for size + nlinks) on Windows.
struct LStatInfo {
    var isDirectory: Bool
    var isSymlink: Bool
    var size: Int64
    var mode: UInt16
    var uid: UInt32
    var gid: UInt32
    var linkCount: Int
    var mtime: Date
}

private func lstatStruct(_ path: String) -> LStatInfo? {
    #if os(Windows)
    var basic = WIN32_FILE_ATTRIBUTE_DATA()
    let success = path.withCString(encodedAs: UTF16.self) { widePath -> Bool in
        GetFileAttributesExW(widePath, GetFileExInfoStandard, &basic)
    }
    if !success { return nil }
    let attrs = basic.dwFileAttributes
    let isDir = (attrs & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0
    let isSym = (attrs & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) != 0
    let isReadOnly = (attrs & DWORD(FILE_ATTRIBUTE_READONLY)) != 0
    let mode: UInt16
    if isDir {
        mode = isReadOnly ? 0o555 : 0o755
    } else {
        mode = isReadOnly ? 0o444 : 0o644
    }
    let size = Int64(basic.nFileSizeHigh) << 32 | Int64(basic.nFileSizeLow)
    let raw = (UInt64(basic.ftLastWriteTime.dwHighDateTime) << 32)
            | UInt64(basic.ftLastWriteTime.dwLowDateTime)
    let mtime = Date(timeIntervalSince1970:
        Double(raw) / 10_000_000.0 - 11_644_473_600)
    return LStatInfo(isDirectory: isDir,
                     isSymlink: isSym,
                     size: size,
                     mode: mode,
                     uid: 0,
                     gid: 0,
                     linkCount: 1,
                     mtime: mtime)
    #else
    var statBuf = stat()
    let result = path.withCString { lstat($0, &statBuf) }
    if result != 0 { return nil }
    let kind = statBuf.st_mode & S_IFMT
    #if canImport(Darwin)
    let mtimeSec = TimeInterval(statBuf.st_mtimespec.tv_sec)
    #else
    let mtimeSec = TimeInterval(statBuf.st_mtim.tv_sec)
    #endif
    return LStatInfo(
        isDirectory: kind == S_IFDIR,
        isSymlink: kind == S_IFLNK,
        size: Int64(statBuf.st_size),
        mode: UInt16(statBuf.st_mode & 0o7777),
        uid: UInt32(statBuf.st_uid),
        gid: UInt32(statBuf.st_gid),
        linkCount: Int(statBuf.st_nlink),
        mtime: Date(timeIntervalSince1970: mtimeSec))
    #endif
}

#if !os(Windows)
private func readAll(fd fileDesc: Int32) -> Data {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buf.withUnsafeMutableBufferPointer { bufPtr in
            read(fileDesc, bufPtr.baseAddress, bufPtr.count)
        }
        if count <= 0 { break }
        data.append(buf, count: count)
    }
    return data
}
// swiftlint:disable:next file_length - sandbox FS plus portable lstat shim in one file
#endif
