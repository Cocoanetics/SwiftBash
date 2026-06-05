import Foundation
import ShellKit

extension ShellKit.Sandbox {

    /// Build the URL gate the SwiftBash sandbox CLI pairs with the
    /// real-disk ``MountedFileSystem`` mounting `workspace` and the
    /// platform's temp dir.
    ///
    /// The gate accepts two virtual roots: the `workspace` mount and
    /// the host's real temp dir (``Foundation.NSTemporaryDirectory()``),
    /// addressable as either `/tmp` (the Unix-y virtual path scripts
    /// expect) or its true platform path. Bash builtins write through
    /// `Shell.fileSystem` to the same host directories; SwiftPorts CLIs
    /// (fd, rg, jq, …) and the SwiftScript interpreter resolve the
    /// same paths through ``Shell/currentDirectory`` /
    /// ``Shell/resolve(_:)`` and authorise them here. Because both
    /// sides land on the same real-disk files, `cd /tmp; mkdir foo;
    /// echo > foo/x; fd x foo` finds the file (#48 / #55) — and the
    /// same works on hosts where `/tmp` doesn't exist (Windows) or
    /// isn't writable (Android emulator) because the host backing is
    /// always the platform's real temp dir (#58).
    ///
    /// The temp carve-out checks **both** the unresolved standardised
    /// path (what the script asked for) and the symlink-resolved path
    /// (what `FileManager` would actually read) — without the second
    /// check a script's `ln -s /etc/passwd /tmp/p` would let
    /// FileManager-backed bridges follow the link out of the sandbox.
    /// The bash-side `MountedFileSystem.canonicalGate` already rejects
    /// this; the URL gate has to match.
    ///
    /// The returned sandbox's `temporaryDirectory` is the host's real
    /// temp dir (the same value `$TMPDIR` carries inside the sandbox)
    /// so ``Shell/temporaryDirectory`` agrees with bash, scripts using
    /// `$TMPDIR`, and FileManager-backed callers.
    /// - Parameter temporaryDirectory: the host dir reported as
    ///   ``Shell/temporaryDirectory``. Defaults to
    ///   `NSTemporaryDirectory()` (the CLI's choice); an embedder that
    ///   isolates `/tmp` per session (e.g. a per-document subdir) passes
    ///   its own. The `/tmp` carve-out still covers it as long as it
    ///   sits under one of the accepted temp prefixes.
    /// - Parameter authorizeNetwork: embedder policy for non-file URLs
    ///   (e.g. routing host access through a permission prompt) while
    ///   still reusing this file-URL gate — `/tmp` carve-out included.
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
                    // only if it lands under an accepted temp prefix.
                    // Compare against `standardizedFileURL` so
                    // `/tmp/./foo` and `/tmp/foo` agree.
                    let unresolved = url.standardizedFileURL.path
                    guard Self.pathIsInTemp(unresolved) else { throw denial }
                    // Canonical (symlink-resolved) path must stay in a
                    // temp prefix too — defends against a bash-staged
                    // `ln -s /etc/passwd /tmp/p` escape.
                    let resolved = url.resolvingSymlinksInPath()
                        .standardizedFileURL.path
                    if !Self.pathIsInTemp(resolved) { throw denial }
                }
            })
    }

    /// Path prefixes the bash sandbox's URL gate treats as "inside
    /// the temp mount":
    ///
    /// - `/tmp` — the Unix-y virtual path scripts use.
    /// - `/private/tmp` — what `/tmp` symlink-resolves to on macOS.
    /// - The platform's real temp dir (`NSTemporaryDirectory()`),
    ///   plus its symlink-resolved spelling, so callers using
    ///   `$TMPDIR` (which carries the same real path) also pass.
    ///
    /// Computed once at first use; Foundation's temp dir is stable
    /// for the lifetime of the process.
    private static let temporaryPrefixes: [String] = {
        var prefixes: [String] = ["/tmp", "/private/tmp"]
        let raw = NSTemporaryDirectory()
        let normalized = (raw as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: normalized)
            .resolvingSymlinksInPath().path
        for path in [normalized, resolved] {
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
    }()

    /// Whether `path` (unresolved or canonical) names a location under
    /// any accepted temp prefix — see ``temporaryPrefixes``.
    private static func pathIsInTemp(_ path: String) -> Bool {
        for prefix in temporaryPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") {
                return true
            }
        }
        return false
    }
}
