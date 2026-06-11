#if !os(Windows)

import Foundation
import BashInterpreter

// MARK: - Host hooks (sandbox / network / identity gating)
//
// Sibling to SwiftScript's `HostHooks.swift`. Every host-touching JS
// builtin (`fs.readFileSync`, `fetch`, `child_process.spawn`, …) calls
// one of these helpers before its Foundation hop. Each helper reads
// `ShellKit.Shell.current` directly: under `Shell.processDefault` the
// gates are no-ops and the standalone `swift-js` CLI behaves exactly
// as it always has.

/// Why a path is being authorized. Mirrors SwiftScript's
/// `PathAccessIntent` so the JS bridge sites read the same way.
enum PathAccessIntent: Sendable {
    case read
    case write
    case delete
}

/// Resolve a JS-side path against the bound shell's logical CWD when
/// it's relative, staying in the SCRIPT-VISIBLE path space. Mirrors
/// Node's `process.chdir` semantics: after `process.chdir("/work")`,
/// `readFileSync("./x")` means `/work/x`.
///
/// Why this matters for sandbox correctness: under a non-default
/// `Shell`, `process.chdir(...)` updates `Shell.current.environment
/// .workingDirectory` but doesn't touch the host process CWD (we
/// can't, the host is shared with the embedder). Without this
/// resolver, every relative-path `fs.*` call would resolve against
/// the host CWD via `URL(fileURLWithPath:)` — so `process.cwd()`
/// would diverge from where `readFileSync("./x")` actually reads.
///
/// The result is what the script gets to SEE (`process.chdir` stores
/// it, `__filename` carries it). For the path to DO I/O on, use
/// ``resolveAgainstShellCWD(_:)``, which adds the virtual→host hop.
func virtualPathAgainstShellCWD(_ path: String) -> String {
    let raw: String
    if (path as NSString).isAbsolutePath {
        raw = path
    } else {
        let cwd = Shell.current === Shell.processDefault
            ? FileManager.default.currentDirectoryPath
            : Shell.current.environment.workingDirectory
        raw = (cwd as NSString).appendingPathComponent(path)
    }
    // Collapse `./` and `../` segments so the gate sees a canonical
    // form. NSString's `standardizingPath` only resolves symlinks
    // when doing so doesn't alter intermediate path components, so
    // sandbox prefix matching stays predictable.
    return (raw as NSString).standardizingPath
}

/// Resolve a JS-side path to the HOST path to do real I/O on: the
/// virtual resolution of ``virtualPathAgainstShellCWD(_:)``, then —
/// when the bound shell's sandbox carries a `PathMapping` (the
/// SwiftBash `--sandbox` case, #83) — translated to the host
/// directory backing the mount, via `Shell.resolve`.
///
/// Every `fs.*` bridge resolves through here and uses the result for
/// BOTH the authorize gate and the Foundation hop. That pairing is
/// load-bearing: translating for the check but not the I/O (or vice
/// versa) would authorize one file and touch another — under a
/// sandbox whose virtual `/tmp` is a per-instance dir, a literal
/// `/tmp/x` would otherwise reach the host's *shared* temp dir.
/// Display output keeps the user's own spelling (the original
/// argument), never this host path.
///
/// Under `Shell.processDefault` (standalone `swift-js`) and under
/// shells without a mapping there is no translation — behaviour is
/// unchanged.
func resolveAgainstShellCWD(_ path: String) -> String {
    let virtual = virtualPathAgainstShellCWD(path)
    return Shell.current.resolve(virtual).path
}

/// Authorize a filesystem access against the bound shell's sandbox.
/// Throws ``ShellKit.Sandbox.Denial`` when the bound sandbox rejects
/// the path; returns silently when no sandbox is bound.
func authorizePath(
    _ path: String,
    for intent: PathAccessIntent = .read
) async throws {
    _ = intent  // reserved for future per-intent rules
    guard let sandbox = Shell.current.sandbox else { return }
    try await sandbox.authorize(URL(fileURLWithPath: path))
}

/// URL-form variant for bridges that already hold a `URL`. Same
/// semantics as the path-string overload.
func authorizePath(
    _ url: URL,
    for intent: PathAccessIntent = .read
) async throws {
    _ = intent
    guard let sandbox = Shell.current.sandbox else { return }
    try await sandbox.authorize(url)
}

/// Authorize a network access against the bound shell's `sandbox`
/// host gate and `networkConfig` allow-list. Returns silently when
/// neither is configured.
func authorizeURL(
    _ url: URL,
    method: String = "GET"
) async throws {
    if let sandbox = Shell.current.sandbox {
        try await sandbox.authorize(url)
    }
    if let config = Shell.current.networkConfig {
        try checkNetworkAllowed(config: config, url: url, method: method)
    }
}

/// Thrown by ``denyProcessIfSandboxed()`` and the JS-side
/// `child_process.*` entry points when a sandbox is bound. JS
/// callers see this surfaced as an `EPERM`-coded `Error`.
struct ProcessDeniedBySandbox: Error, CustomStringConvertible {
    let command: String
    var description: String {
        "spawn \(command) EPERM: process spawn denied by sandbox policy"
    }
}

/// Sync deny gate for `child_process.{exec,execSync,spawn,spawnSync}`.
/// SwiftBash's virtual process table doesn't yet route JS-side spawns,
/// so the right default under a sandbox is to refuse — otherwise
/// `spawn('cat', ['/etc/passwd'])` would round-trip the read through
/// a subprocess and bypass every `fs.*` gate.
func denyProcessIfSandboxed(_ command: String) throws {
    if Shell.current.sandbox != nil {
        throw ProcessDeniedBySandbox(command: command)
    }
}

/// Local copy of SwiftScript's `NetworkConfig.checkAllowed` —
/// pulled in here so SwiftJSCore doesn't take a SwiftScript dep
/// just for the same six lines of allow-list logic.
func checkNetworkAllowed(
    config: NetworkConfig,
    url: URL,
    method: String
) throws {
    if config.dangerouslyAllowFullInternetAccess { return }
    let normalised = method.uppercased()
    // Unknown verbs (LINK, UNLINK, custom WebDAV, …) must be rejected
    // outright — falling back to `.GET` would silently grant a method
    // the embedder never approved, since `fetch(url, { method: "FOO" })`
    // would be evaluated against GET permissions while the actual
    // request method stayed `FOO`.
    guard let knownMethod = HTTPMethod(rawValue: normalised) else {
        throw NetworkAccessDenied(
            url: url,
            reason: "HTTP method \(normalised) not supported by network gate")
    }
    if !config.allowedMethods.contains(knownMethod) {
        throw NetworkAccessDenied(
            url: url,
            reason: "HTTP method \(normalised) not in allow-list")
    }
    let allowed = URLAllowList.isAllowed(
        url.absoluteString,
        entries: config.allowedURLPrefixes)
    guard allowed else {
        throw NetworkAccessDenied(url: url, reason: "URL not in allow-list")
    }
}

struct NetworkAccessDenied: Error, CustomStringConvertible {
    let url: URL
    let reason: String
    var description: String {
        "Network access denied: \(reason): \(url.absoluteString)"
    }
}

extension JSRuntime {

    /// Run an `async throws` operation synchronously by parking the
    /// caller on a semaphore. Used by sync-shaped JS builtins
    /// (`fs.readFileSync`, `fs.writeFileSync`, …) so they can call
    /// the async `authorizePath` / `authorizeURL` gates without
    /// breaking Node's sync contract.
    ///
    /// The current `Shell` binding is captured and re-bound inside
    /// the spawned task — `@TaskLocal` doesn't propagate to detached
    /// tasks, so without the rebind `Shell.current` would resolve to
    /// `processDefault` inside the gate body, defeating the point.
    ///
    /// Must not be called from a queue the spawned task awaits on.
    /// JavaScriptCore's evaluation thread is the intended caller; the
    /// gate body never hops back to it, so there's no deadlock risk.
    func awaitSync<T>(
        _ work: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let captured = Shell.current
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, any Error>!
        Task.detached {
            do {
                let value = try await captured.withCurrent { try await work() }
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }

    /// Throw a Node-shaped `EACCES` JS Error from a `Sandbox.Denial`
    /// or other gate-deny error. Returns the exception so callers can
    /// `return` it from `Any?`-typed bridge blocks.
    @discardableResult
    func throwSandboxDenial(
        _ error: Error,
        syscall: String,
        path: String? = nil
    ) -> JSValue? {
        let reason: String
        if let denial = error as? Sandbox.Denial {
            reason = denial.reason
        } else {
            reason = String(describing: error)
        }
        let pathPart = path.map { ", \(syscall) '\($0)'" } ?? ""
        let msg = "EACCES: permission denied (\(reason))\(pathPart)"
        var extras: [String: Any] = [
            "errno": Int(-EACCES),
            "syscall": syscall
        ]
        if let path { extras["path"] = path }
        return throwJSError(msg, code: "EACCES", extras: extras)
    }

    /// Build (don't throw) a Node-shaped network-deny JS Error for
    /// async paths that need to reject a Promise rather than set
    /// `ctx.exception`.
    func makeNetworkDenialError(
        _ error: Error,
        in ctx: JSContext,
        url: String
    ) -> JSValue {
        let msg: String
        if let denial = error as? Sandbox.Denial {
            msg = "fetch denied: \(denial.reason): \(url)"
        } else if let netDeny = error as? NetworkAccessDenied {
            msg = String(describing: netDeny)
        } else {
            msg = "fetch denied: \(error): \(url)"
        }
        return makeJSError(
            msg,
            in: ctx,
            code: "EACCES",
            extras: ["url": url]
        )
    }
}

#endif  // !os(Windows)
