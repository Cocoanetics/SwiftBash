import Foundation

/// An ``OverlayProvider`` that synthesises `/bin`, `/usr/bin`, and
/// `/usr/local/bin` (plus the intermediate `/usr` and `/usr/local`
/// directories) for the running shell.
///
/// Two sources, split by role:
/// - **Directory geometry** — which bin directories exist — comes from
///   `BinCatalog` ("where would this live on a real macOS install").
///   This is a stable, command-independent set.
/// - **Files** within those directories come from the live command
///   registry (``Shell/commandsByPath``): every file-backed command
///   shows up at its install path. So adding a builtin needs no
///   `BinCatalog` entry — registering it is enough — and off-catalog
///   installs (`install(_:at:)`) are visible just like cataloged ones.
///
/// The shell never executes real on-disk binaries — every command
/// dispatches in-process through ``Shell/commands``. This provider
/// makes that registry *visible* the way a real Unix `ls /bin`
/// would, so scripts inspecting `/bin/cat` get a sensible answer
/// and `which cat` resolves to `/bin/cat`.
///
/// Layout exposed:
///
/// ```
/// /bin/                       (synthesized leaf)
///   cat, cp, ls, mv, …        (each is a stub file)
/// /usr/                       (synthesized intermediate)
///   bin/                      (synthesized leaf)
///     awk, base64, sed, …
///   local/                    (synthesized intermediate)
///     bin/                    (synthesized leaf)
///       rg, yq, …
/// ```
///
/// All entries are read-only. The overlay layer translates any
/// mutation against these paths into `permissionDenied`.
public final class BinCatalogOverlay: OverlayProvider, @unchecked Sendable {

    public init() {}

    // MARK: Catalog geometry

    /// Catalog leaves — `ls /bin` returns files, never directories.
    private var leafDirectories: Set<String> {
        BinCatalog.knownDirectories
    }

    /// Synthetic intermediate directories implied by the catalog
    /// leaves — `/usr` and `/usr/local` today. Computed once.
    private static let intermediateDirectories: Set<String> = {
        var result: Set<String> = []
        for leaf in BinCatalog.knownDirectories {
            var dir = (leaf as NSString).deletingLastPathComponent
            while dir != "/" && !dir.isEmpty {
                result.insert(dir)
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return result
    }()

    /// Basenames of every file-backed command the running shell has
    /// actually installed under `directory`. Driven by the live command
    /// registry (``Shell/commandsByPath``) rather than the static
    /// ``BinCatalog`` map, so off-catalog installs via
    /// ``Shell/install(_:at:)`` — `fd` at `/usr/local/bin/fd`,
    /// `sqlite3` at `/usr/bin/sqlite3` — surface in the synthetic
    /// listing exactly like cataloged commands, with no per-command
    /// `BinCatalog` entry required.
    private func installedCommandNames(in directory: String) -> [String] {
        Shell.bashCurrent.commandsByPath.keys
            .filter { ($0 as NSString).deletingLastPathComponent == directory }
            .map { ($0 as NSString).lastPathComponent }
    }

    private func isLeafDir(_ path: String) -> Bool {
        leafDirectories.contains(path)
    }

    private func isIntermediateDir(_ path: String) -> Bool {
        Self.intermediateDirectories.contains(path)
    }

    /// A synthetic file exists at `path` when a file-backed command is
    /// installed there and its directory is one of the catalog's bin
    /// leaves (`/bin`, `/usr/bin`, `/usr/local/bin`). Registry-driven,
    /// so no per-command ``BinCatalog`` entry is needed for `ls`,
    /// `[ -x … ]`, and tool-presence checks to see an installed CLI.
    private func isSynthesizedFile(_ path: String) -> Bool {
        isLeafDir((path as NSString).deletingLastPathComponent)
            && Shell.bashCurrent.commandsByPath[path] != nil
    }

    // MARK: OverlayProvider

    public func metadata(_ path: String) async throws -> FileMetadata? {
        if isSynthesizedFile(path) {
            return Self.fileMetadata(path: path)
        }
        if isLeafDir(path) || isIntermediateDir(path) {
            return Self.dirMetadata
        }
        return nil
    }

    public func children(under parent: String) async -> [FileEntry] {
        // Leaf directory (`/bin`, `/usr/bin`, …): emit file entries
        // for each registered catalog command.
        if isLeafDir(parent) {
            return installedCommandNames(in: parent)
                .sorted()
                .map { name in
                    let path = (parent as NSString).appendingPathComponent(name)
                    return FileEntry(name: name,
                                     metadata: Self.fileMetadata(path: path))
                }
        }
        // Otherwise: inject any synthetic child *directories* that
        // sit under `parent`. Covers `/` → `[bin, usr]`,
        // `/usr` → `[bin, local]`, `/usr/local` → `[bin]`.
        let all = leafDirectories.union(Self.intermediateDirectories)
        let prefix = parent == "/" ? "/" : parent + "/"
        let directChildNames = all.compactMap { dir -> String? in
            guard dir.hasPrefix(prefix) else { return nil }
            let rest = String(dir.dropFirst(prefix.count))
            return rest.contains("/") ? nil : rest
        }
        return Set(directChildNames)
            .sorted()
            .map {
                FileEntry(name: $0, metadata: Self.dirMetadata)
            }
    }

    public func readData(_ path: String) async throws -> Data {
        guard isSynthesizedFile(path) else {
            throw FileSystemError.notFound(path)
        }
        return Self.stubBytes(
            forCommand: (path as NSString).lastPathComponent)
    }

    // MARK: Stubs

    /// Bytes returned when a script reads a synthesised binary
    /// — e.g. `cat /bin/cat`. There's no real ELF/Mach-O to dump,
    /// so we emit a one-line marker.
    private static func stubBytes(forCommand name: String) -> Data {
        Data("swift-bash built-in command: \(name)\n".utf8)
    }

    /// Synthetic file metadata: regular file, mode `0o755`, owner /
    /// group from the running shell's ``HostInfo`` so identity
    /// stays consistent with `whoami` / `id`. Modification time is
    /// epoch so directory listings stay stable across runs.
    private static func fileMetadata(path: String) -> FileMetadata {
        let host = Shell.bashCurrent.hostInfo
        let stub = stubBytes(
            forCommand: (path as NSString).lastPathComponent)
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

    /// Synthetic directory metadata: mode `0o755`, root-owned,
    /// epoch-dated.
    private static var dirMetadata: FileMetadata {
        let host = Shell.bashCurrent.hostInfo
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
