import Foundation
import ShellKit

extension ShellKit.Sandbox {

    /// Build the URL gate the SwiftBash sandbox CLI pairs with a
    /// ``SandboxedOverlayFileSystem`` mounted at `workspace`.
    ///
    /// The gate accepts two virtual roots: the `workspace` mount point
    /// itself and the in-memory `/tmp` scratch the overlay seeds by
    /// default. SwiftPorts CLIs (fd, rg, jq, …) and the SwiftScript
    /// interpreter resolve paths through ``Shell/currentDirectory`` and
    /// ``Shell/resolve(_:)``, both of which return the bash-side
    /// virtual cwd — `cd /tmp; fd X` lands at virtual `/tmp`. Without
    /// the `/tmp` carve-out, every such call would trip
    /// "file URL is outside sandbox root" even though the bash side
    /// (which consults the overlay, not the URL gate) is fine with the
    /// access (#48). FileManager still walks the host's real `/tmp`
    /// after authorize succeeds, so the in-memory scratch isn't
    /// actually searchable by those CLIs — same shape as the workspace
    /// case where authorize succeeds but the virtual path doesn't
    /// exist on real disk (tracked at Cocoanetics/SwiftPorts#39 and
    /// the existing #10 migration note).
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
