import Foundation

// Symlink target sanitisation. Split out so the main type stays
// within the file_length budget.

extension MountedFileSystem {

    /// Throw `permissionDenied` if `target` (interpreted relative to
    /// `linkPath`'s parent for relative spellings) names a virtual path
    /// outside every mount. Without this check a script-staged
    /// `ln -s /etc/passwd /tmp/p` would write a real host symlink that
    /// FileManager-backed bridges follow straight out of the sandbox.
    func resolveSymlinkTarget(target: String, linkPath: String) throws {
        let linkVirtual = Shell.normalizePath(linkPath)
        let targetVirtual: String
        if Shell.isAbsolutePath(target) {
            targetVirtual = Shell.normalizePath(target)
        } else {
            let parent = (linkVirtual as NSString).deletingLastPathComponent
            let joined = (parent as NSString).appendingPathComponent(target)
            targetVirtual = Shell.normalizePath(joined)
        }
        if synthesizedAncestors.contains(targetVirtual) { return }
        if resolve(targetVirtual) != nil { return }
        throw FileSystemError.permissionDenied(linkPath)
    }
}
