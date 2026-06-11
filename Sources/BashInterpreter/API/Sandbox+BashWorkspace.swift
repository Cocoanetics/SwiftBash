import Foundation
import ShellKit

extension ShellKit.Sandbox {

    /// Build the URL gate the SwiftBash sandbox CLI pairs with the
    /// real-disk ``MountedFileSystem`` mounting `workspace` and a
    /// per-instance temp dir.
    ///
    /// The gate accepts two roots: the `workspace` mount and the
    /// sandbox's temp dir, in the dir's **host** spelling (the same
    /// value `$TMPDIR` carries inside the sandbox). Bash builtins
    /// write through `Shell.fileSystem` to the same host directories;
    /// SwiftPorts CLIs (fd, rg, jq, …) and the SwiftScript interpreter
    /// resolve the same paths through ``Shell/currentDirectory`` /
    /// ``Shell/resolve(_:)`` and authorise them here. Because both
    /// sides land on the same real-disk files, `cd "$TMPDIR"; mkdir
    /// foo; echo > foo/x; fd x foo` finds the file (#48 / #55) — and
    /// the same works on hosts where `/tmp` doesn't exist (Windows) or
    /// isn't writable (Android emulator) because the backing always
    /// lives under the platform's real temp root (#58).
    ///
    /// The gate does NOT accept the virtual `/tmp` spelling: callers
    /// that reach it carry no virtual→host translation (that lands
    /// with #83), so a literal `/tmp/...` here would do real I/O on
    /// the host's `/tmp` — a directory shared with every other
    /// process — instead of this sandbox's temp dir (#82). Until #83,
    /// FileManager-backed callers reach scratch via `$TMPDIR`-spelled
    /// paths only; bash builtins use `/tmp` as usual through the
    /// mount table.
    ///
    /// The temp carve-out checks **both** the unresolved standardised
    /// path (what the script asked for) and the symlink-resolved path
    /// (what `FileManager` would actually read) — without the second
    /// check a script's `ln -s /etc/passwd "$TMPDIR/p"` would let
    /// FileManager-backed bridges follow the link out of the sandbox.
    /// The bash-side `MountedFileSystem.canonicalGate` already rejects
    /// this; the URL gate has to match.
    ///
    /// - Parameter temporaryDirectory: the host dir reported as
    ///   ``Shell/temporaryDirectory`` and accepted by the temp
    ///   carve-out; it should exist when this factory runs so its
    ///   symlink-resolved spelling is computed correctly. The CLI
    ///   passes its per-instance `swiftbash-<UUID>` dir (#82).
    ///   Defaults to `NSTemporaryDirectory()` — note that the default
    ///   shares the platform temp root with every other process and
    ///   sandbox instance.
    /// - Parameter authorizeNetwork: embedder policy for non-file URLs
    ///   (e.g. routing host access through a permission prompt) while
    ///   still reusing this file-URL gate — temp carve-out included.
    ///   When `nil`, non-file URLs are denied (the base gate's
    ///   `allowedHosts: []`), matching the CLI's offline default.
    public static func bashWorkspace(
        workspace: String,
        temporaryDirectory: URL? = nil,
        authorizeNetwork: (@Sendable (URL) async throws -> Void)? = nil
    ) -> ShellKit.Sandbox {
        let workspaceURL = URL(fileURLWithPath: workspace,
                               isDirectory: true)
        let tmpURL = temporaryDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let tempPrefixes = Self.temporaryPrefixes(for: tmpURL)
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
                // Non-file URLs go through the embedder's network policy
                // when supplied; otherwise the deny-all base gate stands.
                guard url.isFileURL else {
                    if let authorizeNetwork {
                        try await authorizeNetwork(url)
                    } else {
                        try await baseSandbox.authorize(url)
                    }
                    return
                }
                do {
                    try await baseSandbox.authorize(url)
                } catch let denial as ShellKit.Sandbox.Denial {
                    // File URL denied by the workspace root — allow it
                    // only if it lands under the sandbox's temp dir.
                    // Compare against `standardizedFileURL` so
                    // `$TMPDIR/./foo` and `$TMPDIR/foo` agree.
                    let unresolved = url.standardizedFileURL.path
                    guard Self.pathIsInTemp(unresolved,
                                            prefixes: tempPrefixes)
                    else { throw denial }
                    // Canonical (symlink-resolved) path must stay in a
                    // temp prefix too — defends against a bash-staged
                    // `ln -s /etc/passwd "$TMPDIR/p"` escape.
                    let resolved = url.resolvingSymlinksInPath()
                        .standardizedFileURL.path
                    if !Self.pathIsInTemp(resolved,
                                          prefixes: tempPrefixes) {
                        throw denial
                    }
                }
            })
    }

    /// Path prefixes the URL gate treats as "inside this sandbox's
    /// temp dir": the dir's verbatim spelling, its normalised one,
    /// and its symlink-resolved one (macOS' temp root lives behind
    /// the `/var → /private/var` link, so `FileManager`'s canonical
    /// paths carry the `/private` form while `$TMPDIR` carries the
    /// bare one). The verbatim spelling matters because
    /// `standardizingPath` may rewrite it — swift-corelibs-foundation
    /// follows symlinks, Darwin strips `/private` — while callers
    /// hand the gate paths built from the `$TMPDIR` value exactly as
    /// the embedder spelled it. Derived per instance — a sibling
    /// sandbox's temp dir under the same platform root never
    /// matches (#82).
    private static func temporaryPrefixes(for tempDir: URL) -> [String] {
        var prefixes: [String] = []
        let normalized = (tempDir.path as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: normalized)
            .resolvingSymlinksInPath().path
        for path in [tempDir.path, normalized, resolved] {
            let stripped: String = {
                if path.count > 1 && path.hasSuffix("/") {
                    return String(path.dropLast())
                }
                return path
            }()
            if !prefixes.contains(stripped) {
                prefixes.append(stripped)
            }
        }
        return prefixes
    }

    /// Whether `path` (unresolved or canonical) names a location under
    /// any accepted temp prefix — see ``temporaryPrefixes(for:)``.
    private static func pathIsInTemp(_ path: String,
                                     prefixes: [String]) -> Bool {
        for prefix in prefixes {
            if path == prefix || path.hasPrefix(prefix + "/") {
                return true
            }
        }
        return false
    }
}
