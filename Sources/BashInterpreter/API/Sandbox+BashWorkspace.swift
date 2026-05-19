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
                    // Allow virtual `/tmp` paths. Compare against the
                    // unresolved standardized path because callers
                    // feed virtual paths (`/tmp/foo`), not realpath'd
                    // host paths (`/private/tmp/foo` on macOS).
                    if url.isFileURL {
                        let path = url.standardizedFileURL.path
                        if path == "/tmp" || path.hasPrefix("/tmp/") {
                            return
                        }
                    }
                    throw denial
                }
            })
    }
}
