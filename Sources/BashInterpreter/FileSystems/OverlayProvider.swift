import Foundation

/// A source of virtual files and directories layered onto an
/// ``OverlayFileSystem``'s backing file system.
///
/// Providers expose three things to the overlay:
///
/// 1. **Metadata** — `metadata(_:)` is the source of truth for
///    "do you claim this path?" Returning non-nil means the
///    overlay routes reads, write rejections, and stat operations
///    to this provider; returning nil falls through to the backing
///    FS (or the next provider).
/// 2. **Listings** — `children(under:)` returns the
///    direct children this provider injects when the overlay lists
///    a directory. Includes both files this provider exposes and
///    synthesized intermediate directories needed to reach them.
/// 3. **Reads** — `openRead(_:)` and `readData(_:)` return the bytes
///    for files this provider claims. The overlay only invokes
///    these on paths the provider claims.
///
/// Providers don't need to handle mutations — the overlay wraps
/// every write/chmod/move/remove with a `permissionDenied` if any
/// provider claims the path. Overlay content is uniformly read-only.
public protocol OverlayProvider: Sendable {

    /// Return metadata for `path` if this provider claims it.
    /// `nil` means "I don't own this path"; the overlay then
    /// asks the next provider, or falls through to the backing FS.
    func metadata(_ path: String) async throws -> FileMetadata?

    /// Direct children of `parent` that this provider exposes —
    /// both the files it owns and any synthesized intermediate
    /// directories on the way to its content (so `ls /` shows
    /// `bin` and `usr` next to backing entries when a
    /// `BinCatalogOverlay` is layered above the disk).
    ///
    /// Return an empty array when the provider doesn't own anything
    /// under `parent`; non-error path because providers commonly
    /// don't claim arbitrary directories.
    func children(under parent: String) async -> [FileEntry]

    /// Read the bytes for a file this provider claims. Only invoked
    /// for paths the overlay has already confirmed the provider
    /// owns via `metadata(_:)`.
    func readData(_ path: String) async throws -> Data

    /// Open a file this provider claims for streaming reads.
    /// Defaults to wrapping `readData(_:)` in an in-memory source.
    func openRead(_ path: String) async throws -> InputSource
}

public extension OverlayProvider {
    func openRead(_ path: String) async throws -> InputSource {
        .data(try await readData(path))
    }
}
