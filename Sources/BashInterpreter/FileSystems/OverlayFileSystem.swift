import Foundation

/// A ``FileSystem`` that layers one or more ``OverlayProvider`` sources
/// of virtual content on top of a writable backing file system.
///
/// Each provider can claim any subtree of the virtual namespace and
/// expose synthetic files and directories there. Reads short-circuit
/// to the first provider that claims the path; if none do, the call
/// forwards to the backing FS. Mutations against any claimed path
/// throw ``FileSystemError/permissionDenied(_:)`` — overlay content
/// is uniformly read-only. Directory listings merge entries from
/// every claimant with the backing FS's entries, deduplicated by
/// name (providers win on conflict, in the order they appear in the
/// `providers` array).
///
/// Embedders use this to surface things that don't live on disk:
/// - ``BinCatalogOverlay`` synthesises `/bin`, `/usr/bin`, and
///   `/usr/local/bin` from the running shell's command registry.
/// - ``HostDirectoryOverlay`` exposes a host directory tree at a
///   chosen virtual path, read-only — useful for shipping example
///   files in the app bundle without seeding them onto disk.
///
/// The wrapper is transparent: any path the providers don't claim
/// reaches the backing FS untouched, so the chrooted-shell guarantee
/// of ``MountedFileSystem`` keeps working when layered below.
public final class OverlayFileSystem: FileSystem, @unchecked Sendable {

    public let backing: any FileSystem
    public let providers: [any OverlayProvider]

    public init(backing: any FileSystem,
                providers: [any OverlayProvider]) {
        self.backing = backing
        self.providers = providers
    }

    // MARK: Helpers

    /// First provider that claims `path`, or nil if no provider does.
    /// "Claim" means `metadata(_:)` returned non-nil — that's the
    /// single source of truth.
    private func provider(for path: String) async -> (any OverlayProvider)? {
        for provider in providers
        where ((try? await provider.metadata(path)) ?? nil) != nil {
            return provider
        }
        return nil
    }

    /// `true` if `path` lies under any overlay-claimed directory (or
    /// is the claimed path itself). Used by mutating operations:
    /// `mkdir /usr/whatever` should fail with `permissionDenied`
    /// because `/usr` is an overlay-owned read-only directory — not
    /// surface the backing FS's "no parent" error, which would be
    /// both misleading and exposable to attempts at filling in the
    /// gap.
    private func isUnderOverlay(_ path: String) async -> Bool {
        var current = path
        while !current.isEmpty {
            if await provider(for: current) != nil { return true }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }     // hit root
            current = parent
        }
        return false
    }

    // MARK: Inspection

    public func metadata(_ path: String) async throws -> FileMetadata? {
        for provider in providers {
            if let meta = try await provider.metadata(path) { return meta }
        }
        return try await backing.metadata(path)
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        var byName: [String: FileEntry] = [:]
        var seenOwner = false
        // Providers first: each one contributes its synthetic
        // children. A provider that doesn't claim `path` returns
        // an empty list cleanly.
        for provider in providers {
            let entries = await provider.children(under: path)
            if !entries.isEmpty { seenOwner = true }
            // First provider wins on name collisions.
            for entry in entries where byName[entry.name] == nil {
                byName[entry.name] = entry
            }
        }
        // Backing entries: anything not already provided by an
        // overlay is appended. If no provider claimed this path and
        // the backing FS doesn't have it either, the backing error
        // (notFound / notADirectory) surfaces. If at least one
        // provider claimed it, we tolerate a missing backing dir.
        let backingEntries: [FileEntry]
        if seenOwner {
            backingEntries = (try? await backing.list(path)) ?? []
        } else {
            backingEntries = try await backing.list(path)
        }
        for entry in backingEntries where byName[entry.name] == nil {
            byName[entry.name] = entry
        }
        return Array(byName.values)
    }

    public func canonicalize(_ path: String,
                             allowMissing: Bool) async throws -> String {
        if await provider(for: path) != nil { return path }
        return try await backing.canonicalize(path, allowMissing: allowMissing)
    }

    // MARK: Reading

    public func readData(_ path: String) async throws -> Data {
        for provider in providers {
            if let meta = try await provider.metadata(path) {
                if meta.kind == .directory {
                    throw FileSystemError.isADirectory(path)
                }
                return try await provider.readData(path)
            }
        }
        return try await backing.readData(path)
    }

    public func openRead(_ path: String) async throws -> InputSource {
        for provider in providers {
            if let meta = try await provider.metadata(path) {
                if meta.kind == .directory {
                    throw FileSystemError.isADirectory(path)
                }
                return try await provider.openRead(path)
            }
        }
        return try await backing.openRead(path)
    }

    // MARK: Writes — overlay content is read-only

    public func writeData(_ data: Data, to path: String,
                          append: Bool) async throws {
        if await isUnderOverlay(path) {
            throw FileSystemError.permissionDenied(path)
        }
        try await backing.writeData(data, to: path, append: append)
    }

    public func openWrite(_ path: String,
                          append: Bool) async throws -> OutputSink {
        if await isUnderOverlay(path) {
            throw FileSystemError.permissionDenied(path)
        }
        return try await backing.openWrite(path, append: append)
    }

    public func touch(_ path: String) async throws {
        if await isUnderOverlay(path) {
            throw FileSystemError.permissionDenied(path)
        }
        try await backing.touch(path)
    }

    public func createDirectory(_ path: String,
                                intermediates: Bool) async throws {
        if await provider(for: path) != nil {
            throw FileSystemError.alreadyExists(path)
        }
        if await isUnderOverlay(path) {
            throw FileSystemError.permissionDenied(path)
        }
        try await backing.createDirectory(path, intermediates: intermediates)
    }

    public func remove(_ path: String, recursive: Bool) async throws {
        if await isUnderOverlay(path) {
            throw FileSystemError.permissionDenied(path)
        }
        try await backing.remove(path, recursive: recursive)
    }

    // `to:` matches the FileSystem protocol's public signature.
    // swiftlint:disable:next identifier_name
    public func move(from: String, to: String) async throws {
        let fromOwned = await isUnderOverlay(from)
        let toOwned   = await isUnderOverlay(to)
        if fromOwned || toOwned {
            throw FileSystemError.permissionDenied(from)
        }
        try await backing.move(from: from, to: to)
    }

    // `to:` matches the FileSystem protocol's public signature.
    // swiftlint:disable:next identifier_name
    public func copy(from: String, to: String) async throws {
        if await provider(for: to) != nil {
            throw FileSystemError.permissionDenied(to)
        }
        // Read-source-from-provider, write-dest-to-backing: lets
        // users `cp /examples/foo.sh ~/foo.sh` even though
        // `/examples` is a provider mount.
        if let src = await provider(for: from) {
            let data = try await src.readData(from)
            try await backing.writeData(data, to: to, append: false)
            return
        }
        try await backing.copy(from: from, to: to)
    }

    public func makeTempPath(prefix: String) async throws -> String {
        try await backing.makeTempPath(prefix: prefix)
    }

    // MARK: Permissions / ownership / xattrs — all denied on overlays,
    // forwarded otherwise.

    public func chmod(_ path: String, mode: UInt16) async throws {
        if await provider(for: path) != nil {
            throw FileSystemError.permissionDenied(path)
        }
        try await backing.chmod(path, mode: mode)
    }

    public func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
        if await provider(for: path) != nil {
            throw FileSystemError.permissionDenied(path)
        }
        try await backing.chown(path, uid: uid, gid: gid)
    }

    public func symlink(target: String, at linkPath: String) async throws {
        if await provider(for: linkPath) != nil {
            throw FileSystemError.permissionDenied(linkPath)
        }
        try await backing.symlink(target: target, at: linkPath)
    }

    public func hardlink(target: String, at linkPath: String) async throws {
        if await provider(for: linkPath) != nil {
            throw FileSystemError.permissionDenied(linkPath)
        }
        try await backing.hardlink(target: target, at: linkPath)
    }

    public func listXattrs(_ path: String) async throws -> [String] {
        if await provider(for: path) != nil { return [] }
        return try await backing.listXattrs(path)
    }

    public func getXattr(_ path: String, name: String) async throws -> Data {
        if await provider(for: path) != nil {
            throw FileSystemError.io("no such xattr: \(name)")
        }
        return try await backing.getXattr(path, name: name)
    }

    public func setXattr(_ path: String, name: String, value: Data) async throws {
        if await provider(for: path) != nil {
            throw FileSystemError.permissionDenied(path)
        }
        try await backing.setXattr(path, name: name, value: value)
    }

    public func removeXattr(_ path: String, name: String) async throws {
        if await provider(for: path) != nil { return }
        try await backing.removeXattr(path, name: name)
    }
}
