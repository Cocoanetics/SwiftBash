import Foundation

/// An ``OverlayProvider`` that exposes a host directory tree at a
/// chosen virtual path, read-only.
///
/// Useful for shipping content with an app bundle without seeding it
/// onto the user's disk per-document. iBash uses this to mount
/// `Bundle.main.url(forResource: "Examples", withExtension: nil)`
/// at the virtual path `/examples` — the user sees the examples,
/// can `cat` and `bash` them, but the .ibash document folder never
/// holds a copy and the examples are always fresh from the app
/// bundle.
///
/// Paths under `virtualRoot` map directly to the host filesystem:
/// `/examples/bash/hello.sh` → `<hostRoot>/bash/hello.sh`. Anything
/// outside `virtualRoot` is not claimed.
///
/// The overlay layer rejects every mutation against any path this
/// provider claims, so the host tree is safe even if the host
/// directory itself is writable.
public final class HostDirectoryOverlay: OverlayProvider, @unchecked Sendable {

    public let virtualRoot: String
    public let hostRoot: URL

    /// - Parameters:
    ///   - virtualRoot: The virtual path this overlay mounts at,
    ///     e.g. `/examples`. Must be absolute. The directory itself
    ///     and everything below it is owned by this provider.
    ///   - hostRoot: The host directory whose contents are exposed.
    ///     Typically an app-bundle resource URL.
    public init(virtualRoot: String, hostRoot: URL) {
        // Strip trailing slash if any so prefix comparisons are
        // deterministic.
        var trimmed = virtualRoot
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.virtualRoot = trimmed
        self.hostRoot = hostRoot.standardizedFileURL
    }

    // MARK: Path mapping

    /// Translate a virtual path to a host URL, or `nil` if the path
    /// isn't under this overlay's `virtualRoot`.
    private func hostURL(for virtualPath: String) -> URL? {
        if virtualPath == virtualRoot { return hostRoot }
        let prefix = virtualRoot == "/" ? "/" : virtualRoot + "/"
        guard virtualPath.hasPrefix(prefix) else { return nil }
        let rel = String(virtualPath.dropFirst(prefix.count))
        return hostRoot.appendingPathComponent(rel)
    }

    // MARK: OverlayProvider

    public func metadata(_ path: String) async throws -> FileMetadata? {
        guard let url = hostURL(for: path) else { return nil }
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return nil
        }
        return Self.readOnlyMetadata(at: url, isDirectory: isDir.boolValue)
    }

    public func children(under parent: String) async -> [FileEntry] {
        // Inject `<basename>` for the overlay's own root when
        // listing the parent of `virtualRoot`. So if `virtualRoot`
        // is `/examples`, listing `/` should see `examples`.
        let parentOfRoot = (virtualRoot as NSString).deletingLastPathComponent
        if parent == parentOfRoot,
           let meta = try? await metadata(virtualRoot) {
            let name = (virtualRoot as NSString).lastPathComponent
            return [FileEntry(name: name, metadata: meta)]
        }
        // Otherwise, list the host directory if `parent` falls
        // inside our virtual root.
        guard let url = hostURL(for: parent) else { return [] }
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue
        else { return [] }
        guard let names = try? fileManager.contentsOfDirectory(atPath: url.path) else {
            return []
        }
        var result: [FileEntry] = []
        result.reserveCapacity(names.count)
        for name in names {
            let child = url.appendingPathComponent(name)
            var childIsDir: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path,
                                isDirectory: &childIsDir) else { continue }
            let meta = Self.readOnlyMetadata(
                at: child, isDirectory: childIsDir.boolValue)
            result.append(FileEntry(name: name, metadata: meta))
        }
        return result.sorted { $0.name < $1.name }
    }

    public func readData(_ path: String) async throws -> Data {
        guard let url = hostURL(for: path) else {
            throw FileSystemError.notFound(path)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw FileSystemError.notFound(path)
        }
    }

    public func openRead(_ path: String) async throws -> InputSource {
        .data(try await readData(path))
    }

    // MARK: Metadata helpers

    /// Read host file metadata and force the result read-only. The
    /// host file's actual mode is irrelevant — the overlay layer
    /// rejects every mutation, so reporting `0o555` (read+execute,
    /// no write) keeps the surface consistent with `ls -l`. The +x
    /// bit lets bash exec shebang-marked example scripts like
    /// `/examples/swift/hello.swift` directly (the registered
    /// shebang handlers then pick them up).
    private static func readOnlyMetadata(at url: URL,
                                         isDirectory: Bool) -> FileMetadata {
        let attrs = (try? FileManager.default
            .attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? Date()
        let mode: UInt16 = 0o555
        return FileMetadata(
            kind: isDirectory ? .directory : .file,
            size: size,
            modifiedAt: modified,
            mode: mode,
            uid: 0,
            gid: 0,
            linkCount: isDirectory ? 2 : 1,
            accessedAt: modified,
            createdAt: modified)
    }
}
