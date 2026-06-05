import Foundation

// Synthesised virtual directories on the way to a real mount. Split
// from `MountedFileSystem.swift` so the main type stays within the
// `type_body_length` budget.

extension MountedFileSystem {

    /// Compute the set of synthesised ancestor directories implied by
    /// `mounts`. A mount at `/usr/bin` synthesises `/usr` (and `/`) so
    /// `cd /usr` and `ls /` work without the caller declaring a root
    /// mount. Ancestors that are themselves concrete mount points
    /// drop out — those resolve via the regular mount table because
    /// real disk wins over synthesis.
    static func computeSynthesizedAncestors(_ mounts: [Mount]) -> Set<String> {
        var ancestors: Set<String> = []
        for mount in mounts where mount.virtual != "/" {
            var dir = (mount.virtual as NSString).deletingLastPathComponent
            while !dir.isEmpty {
                ancestors.insert(dir)
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir { break }
                dir = parent
            }
        }
        for mount in mounts { ancestors.remove(mount.virtual) }
        return ancestors
    }

    /// Direct child names `parent` should expose by virtue of the mount
    /// table — the first path component of every mount (and synthesised
    /// ancestor) whose virtual path lies under `parent`, deduplicated.
    /// Used both for a fully-synthesised ancestor (which has no backing
    /// directory of its own) and to fold cross-store mount points into a
    /// concrete mount's host listing (so `/tmp` shows up under `ls /`).
    func synthesizedChildren(of parent: String) -> [FileEntry] {
        let prefix = parent == "/" ? "/" : parent + "/"
        var seen: Set<String> = []
        var entries: [FileEntry] = []
        let allVirtuals = Set(allMountVirtuals)
            .union(synthesizedAncestors)
        for virtual in allVirtuals where virtual.hasPrefix(prefix) {
            let rest = String(virtual.dropFirst(prefix.count))
            let head = rest.split(separator: "/",
                                  omittingEmptySubsequences: true)
                .first.map(String.init) ?? rest
            guard !head.isEmpty, seen.insert(head).inserted else { continue }
            entries.append(FileEntry(
                name: head,
                metadata: Self.synthesizedDirMetadata()))
        }
        return entries
    }

    static func synthesizedDirMetadata() -> FileMetadata {
        let date = Date(timeIntervalSince1970: 0)
        return FileMetadata(
            kind: .directory,
            size: 0,
            modifiedAt: date,
            mode: 0o755,
            uid: 0,
            gid: 0,
            linkCount: 2,
            accessedAt: date,
            createdAt: date)
    }
}
