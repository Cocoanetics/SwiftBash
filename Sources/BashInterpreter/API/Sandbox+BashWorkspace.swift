import Foundation
import ShellKit

extension ShellKit.Sandbox {

    /// Build the URL gate the SwiftBash sandbox CLI pairs with the
    /// real-disk ``MountedFileSystem`` mounting `workspace` and `/tmp`.
    ///
    /// The gate accepts two virtual roots: the `workspace` mount and
    /// `/tmp`. Bash builtins write through `Shell.fileSystem` to the
    /// real host directories those mounts back onto; SwiftPorts CLIs
    /// (fd, rg, jq, …) and the SwiftScript interpreter resolve the
    /// same virtual paths through ``Shell/currentDirectory`` /
    /// ``Shell/resolve(_:)`` and authorise them here. Because both
    /// sides land on the same real-disk files, `cd /tmp; mkdir foo;
    /// echo > foo/x; fd x foo` finds the file (#48 / #55).
    ///
    /// The `/tmp` carve-out checks **both** the unresolved standardised
    /// path (what the script asked for) and the symlink-resolved path
    /// (what `FileManager` would actually read) — without the second
    /// check a script's `ln -s /etc/passwd /tmp/p` would let
    /// FileManager-backed bridges follow the link out of the sandbox.
    /// The bash-side `MountedFileSystem.canonicalGate` already rejects
    /// this; the URL gate has to match.
    ///
    /// The returned sandbox's `temporaryDirectory` is `/tmp` (the
    /// virtual path scripts see via `$TMPDIR`), not the default
    /// `<workspace>/tmp` that ``rooted(at:allowedHosts:)`` would
    /// produce — that keeps ``Shell/temporaryDirectory`` aligned with
    /// the path bash code actually uses.
    public static func bashWorkspace(workspace: String) -> ShellKit.Sandbox {
        let workspaceURL = URL(fileURLWithPath: workspace,
                               isDirectory: true)
        let tmpURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let baseSandbox = ShellKit.Sandbox.rooted(
            at: workspaceURL,
            allowedHosts: [])
        return ShellKit.Sandbox(
            documentsDirectory: baseSandbox.documentsDirectory,
            downloadsDirectory: baseSandbox.downloadsDirectory,
            libraryDirectory: baseSandbox.libraryDirectory,
            moviesDirectory: baseSandbox.moviesDirectory,
            musicDirectory: baseSandbox.musicDirectory,
            picturesDirectory: baseSandbox.picturesDirectory,
            sharedPublicDirectory: baseSandbox.sharedPublicDirectory,
            temporaryDirectory: tmpURL,
            trashDirectory: baseSandbox.trashDirectory,
            userDirectory: baseSandbox.userDirectory,
            cachesDirectory: baseSandbox.cachesDirectory,
            homeDirectory: baseSandbox.homeDirectory,
            authorize: { url in
                do {
                    try await baseSandbox.authorize(url)
                } catch let denial as ShellKit.Sandbox.Denial {
                    guard url.isFileURL else { throw denial }
                    // Unresolved virtual path must be in `/tmp`. Compare
                    // against `standardizedFileURL` so `/tmp/./foo` and
                    // `/tmp/foo` agree.
                    let unresolved = url.standardizedFileURL.path
                    guard Self.pathIsInTmp(unresolved) else { throw denial }
                    // Canonical (symlink-resolved) path must stay in
                    // `/tmp` too — defends against a bash-staged
                    // `ln -s /etc/passwd /tmp/p` escape.
                    let resolved = url.resolvingSymlinksInPath()
                        .standardizedFileURL.path
                    if !Self.pathIsInTmp(resolved) { throw denial }
                }
            })
    }

    /// Whether `path` (unresolved or canonical) names a location under
    /// the host `/tmp`. On macOS `/tmp` itself is a symlink to
    /// `/private/tmp`, so the canonical form of every `/tmp` write
    /// shows up as `/private/tmp/...` — accept either spelling.
    private static func pathIsInTmp(_ path: String) -> Bool {
        path == "/tmp" || path.hasPrefix("/tmp/")
            || path == "/private/tmp" || path.hasPrefix("/private/tmp/")
    }
}
