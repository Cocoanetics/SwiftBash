#if !os(Windows)

import Foundation
import BashInterpreter

extension JSRuntime {

    /// Wires up `require()`, the builtin module table (node:fs,
    /// node:path, node:os, node:url, node:util), and a CommonJS
    /// loader for relative-path requires.
    func installModules() {
        installRequire()
        registerBuiltinModules()
    }

    private func installRequire() {
        // require() table: spec → cached JSValue. Builtin modules are
        // loaded eagerly at startup; local files lazily on first
        // require, then cached.
        let cacheKey = "__swiftjs_module_cache"
        context.evaluateScript("globalThis.\(cacheKey) = {};")

        let requireImpl = block { [weak self] args in
            guard let self, let spec = args.first?.toString() else { return nil }
            return self.resolveRequire(spec)
        }
        setGlobal("require", requireImpl)
    }

    /// Resolve a require spec. Returns the module's `exports` value.
    private func resolveRequire(_ spec: String) -> Any? {
        // Builtin modules (registered eagerly in
        // `registerBuiltinModules`). Both `fs` and `node:fs` work.
        if let cached = lookupCache(spec) { return cached }

        // Relative or absolute path → load file.
        if spec.hasPrefix("./") || spec.hasPrefix("../") || spec.hasPrefix("/") {
            return loadFileModule(spec)
        }

        return throwJSError("Cannot find module '\(spec)'", code: "MODULE_NOT_FOUND")
    }

    /// Look up the cache directly via the JS object (don't go through
    /// `toDictionary()`, which unwraps JSValue into native types).
    private func lookupCache(_ key: String) -> JSValue? {
        guard let cache = context.objectForKeyedSubscript("__swiftjs_module_cache"),
              !cache.isUndefined else { return nil }
        let value = cache.objectForKeyedSubscript(key)
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        return value
    }

    private func cacheBuiltin(_ name: String, _ value: JSValue) {
        let cache = context.objectForKeyedSubscript("__swiftjs_module_cache")!
        cache.setObject(value, forKeyedSubscript: name as NSString)
    }

    // CommonJS file loader: resolution + sandbox gate + wrapper +
    // cache. Mirrors Node's algorithm closely enough that the inline
    // commentary is the cleanest way to read it.
    // swiftlint:disable:next function_body_length
    private func loadFileModule(_ spec: String) -> Any? {
        // `require("./x")` with no calling-module context (entry-point
        // script reading via `vm.runInThisContext` etc.) falls back to
        // CWD. Use the bound shell's logical CWD, not the host process
        // CWD, so this stays consistent with `process.cwd()` and with
        // the `fs.*` resolver that follows.
        let basePath = (currentScriptPath as NSString?)?.deletingLastPathComponent
            ?? (Shell.current === Shell.processDefault
                ? FileManager.default.currentDirectoryPath
                : Shell.current.environment.workingDirectory)
        let base = (spec as NSString).hasPrefix("/")
            ? spec
            : (basePath as NSString).appendingPathComponent(spec)

        // Candidate spellings in Node's resolution order: the bare
        // path, then the implicit extensions. Each is a script-visible
        // (virtual) spelling — the cache key, `__filename` /
        // `__dirname`, and the stack-frame source URL all carry it;
        // its HOST translation (`Shell.resolve`; identity without a
        // sandbox path mapping) drives the gate and disk access.
        let cacheStore = context.objectForKeyedSubscript("__swiftjs_module_cache")
        let fileManager = FileManager.default
        let candidates = [base]
            + [".js", ".mjs", ".cjs", ".json"].map { base + $0 }

        var resolved = ""
        var hostPath = ""
        var found = false
        for candidate in candidates {
            // Cache hit short-circuits before any gate / disk touch —
            // a cached module was authorized when first loaded.
            if let cached = cacheStore?.objectForKeyedSubscript(candidate),
               !cached.isUndefined, !cached.isNull {
                return cached
            }
            let candidateHost = ShellKit.Shell.current.resolve(candidate).path
            // Authorize BEFORE probing the filesystem, and treat a
            // denied candidate exactly like a missing one (keep
            // looking, ultimately MODULE_NOT_FOUND). Probing first
            // would `stat` through a workspace symlink that escapes
            // the sandbox before the gate runs, letting a script tell
            // an existing outside target from a missing one via the
            // error shape (Codex P2 on #88). Folding deny into
            // not-found closes that oracle: neither the gate result
            // nor a stat reveals anything outside the namespace.
            let authorized = (try? awaitSync {
                try await authorizePath(candidateHost, for: .read)
            }) != nil
            guard authorized,
                  fileManager.fileExists(atPath: candidateHost)
            else { continue }
            resolved = candidate
            hostPath = candidateHost
            found = true
            break
        }
        guard found else {
            return throwJSError("Cannot find module '\(spec)'",
                                code: "MODULE_NOT_FOUND")
        }

        guard let source = try? String(contentsOfFile: hostPath, encoding: .utf8) else {
            return throwJSError("Cannot find module '\(spec)'", code: "MODULE_NOT_FOUND")
        }

        // .json files load as parsed JSON (Node behaviour).
        if resolved.hasSuffix(".json") {
            let parser = context.objectForKeyedSubscript("JSON")!
            let value = parser.invokeMethod("parse", withArguments: [source])
            let cache = context.objectForKeyedSubscript("__swiftjs_module_cache")!
            cache.setObject(value as Any, forKeyedSubscript: resolved as NSString)
            return value
        }

        // Rewrite ESM-isms before wrapping so that `.mjs` files (or
        // `.js` files written in module syntax) work the same as
        // CommonJS `require`d modules.
        let rewritten = ESMRewriter.rewrite(source)

        // CommonJS wrapper. The prefix lives on the same line as the
        // user's first line of source so JSC's stack-frame line
        // numbers map directly back to the original file (Node does
        // the same trick for the same reason). Column numbers on line
        // 1 are still off by `prefix.count`, but that's the standard
        // Node offset and tools that consume stack traces handle it.
        let prefix = "(function(exports, require, module, __filename, __dirname) { "
        let wrapped = prefix + rewritten + "\n})"
        let url = URL(fileURLWithPath: resolved)
        guard let factory = context.evaluateScript(wrapped, withSourceURL: url),
              !factory.isUndefined else {
            return nil
        }

        let module = JSValue(newObjectIn: context)!
        let exports = JSValue(newObjectIn: context)!
        module.setObject(exports, forKeyedSubscript: "exports" as NSString)

        // Cache before invoking the factory so circular requires
        // don't loop forever — Node does the same.
        let cache = context.objectForKeyedSubscript("__swiftjs_module_cache")!
        cache.setObject(exports, forKeyedSubscript: resolved as NSString)

        let prev = currentScriptPath
        currentScriptPath = resolved
        defer { currentScriptPath = prev }

        let dirname = (resolved as NSString).deletingLastPathComponent
        let requireGlobal = context.objectForKeyedSubscript("require")!
        factory.call(withArguments: [exports, requireGlobal, module, resolved, dirname])

        let finalExports = module.objectForKeyedSubscript("exports")!
        cache.setObject(finalExports, forKeyedSubscript: resolved as NSString)
        return finalExports
    }

    // MARK: - Builtin modules

    private func registerBuiltinModules() {
        let fsModule = makeFsModule()
        cacheBuiltin("fs", fsModule)
        cacheBuiltin("node:fs", fsModule)

        let path = makePathModule()
        cacheBuiltin("path", path)
        cacheBuiltin("node:path", path)

        let osModule = makeOsModule()
        cacheBuiltin("os", osModule)
        cacheBuiltin("node:os", osModule)

        let util = makeUtilModule()
        cacheBuiltin("util", util)
        cacheBuiltin("node:util", util)

        let urlMod = makeUrlModule()
        cacheBuiltin("url", urlMod)
        cacheBuiltin("node:url", urlMod)

        let cryptoMod = makeCryptoModule()
        cacheBuiltin("crypto", cryptoMod)
        cacheBuiltin("node:crypto", cryptoMod)

        let cpMod = makeChildProcessModule()
        cacheBuiltin("child_process", cpMod)
        cacheBuiltin("node:child_process", cpMod)

        let fsPromises = makeFsPromisesModule(syncFs: fsModule)
        cacheBuiltin("node:fs/promises", fsPromises)
        cacheBuiltin("fs/promises", fsPromises)

        let zlibMod = makeZlibModule()
        cacheBuiltin("zlib", zlibMod)
        cacheBuiltin("node:zlib", zlibMod)

        let assertMod = makeAssertModule()
        cacheBuiltin("assert", assertMod)
        cacheBuiltin("node:assert", assertMod)
        cacheBuiltin("assert/strict", assertMod)
        cacheBuiltin("node:assert/strict", assertMod)

        let eventsMod = makeEventsModule()
        cacheBuiltin("events", eventsMod)
        cacheBuiltin("node:events", eventsMod)

        let qsMod = makeQuerystringModule()
        cacheBuiltin("querystring", qsMod)
        cacheBuiltin("node:querystring", qsMod)

        let perfMod = makePerfHooksModule()
        cacheBuiltin("perf_hooks", perfMod)
        cacheBuiltin("node:perf_hooks", perfMod)

        // node:stream depends on EventEmitter being cached, so register
        // it after `events`.
        let streamWrapper = makeStreamWrapper()
        cacheBuiltin("stream", streamWrapper)
        cacheBuiltin("node:stream", streamWrapper)
    }

    /// `node:stream` wrapper — the Readable/Writable pair plus a
    /// `default`/named-export shape for ESM ergonomics.
    private func makeStreamWrapper() -> JSValue {
        let streamMod = makeStreamModule()
        let streamWrapper = JSValue(newObjectIn: context)!
        streamWrapper.setObject(streamMod.objectForKeyedSubscript("Readable")!,
                                forKeyedSubscript: "Readable" as NSString)
        streamWrapper.setObject(streamMod.objectForKeyedSubscript("Writable")!,
                                forKeyedSubscript: "Writable" as NSString)
        streamWrapper.setObject(streamWrapper,
                                forKeyedSubscript: "default" as NSString)
        return streamWrapper
    }
}

#endif  // !os(Windows)
