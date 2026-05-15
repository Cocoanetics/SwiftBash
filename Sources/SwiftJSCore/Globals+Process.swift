#if !os(Windows)

import Foundation
import BashInterpreter

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - process.* bindings split out of `Globals.swift`.

extension JSRuntime {

    func installProcess() {
        let process = JSValue(newObjectIn: context)!

        // process.argv: a regular JS Array snapshotted from the
        // provider. Matches Node — it's a real array, supports
        // for-of/spread/slice, and mutations are local to the
        // reference (don't propagate back to the provider).
        // Embedders that need to update it mid-run can call
        // ``JSRuntime.refreshArgv()`` to re-sync from the provider.
        process.setObject(argvProvider.argv(), forKeyedSubscript: "argv")

        // process.env is a JS Proxy that routes every read/write
        // through the EnvProvider. Setting `process.env.X = "y"`
        // calls envProvider.set(...), which for OSEnvProvider also
        // propagates to setenv() so child processes see the change.
        //
        // Identity redirect: when an embedder has bound a non-default
        // Shell (i.e. there's confinement in play), reads and writes
        // route through `Shell.current.environment.variables` instead
        // — so a sandboxed JS script sees the bound shell's env, not
        // the host's. Under `Shell.processDefault` (standalone CLI)
        // we keep the legacy `OSEnvProvider`-via-`setenv` behaviour
        // so child processes spawned by the host still see writes.
        installEnvProxy(on: process)
        installPlatformMetadata(on: process)
        installPidGetters(on: process)
        installExitAndCwd(on: process)
        installStdoutStderr(on: process)
        installProcessEvents(on: process)
        installExitCodeAccessor()
        setGlobal("process", process)

        // Define exitCode as an accessor on process so reads/writes
        // round-trip through the runtime's `exitCode` field.
        // Capture the bridges by closure (not name lookup) so we can
        // safely scrub the globals afterwards.
        context.evaluateScript(#"""
        (() => {
          const G = globalThis.__swiftjs_exitCodeGet;
          const S = globalThis.__swiftjs_exitCodeSet;
          Object.defineProperty(process, "exitCode", {
            get() { return G(); },
            set(v) { S(v); },
            enumerable: true,
          });
          delete globalThis.__swiftjs_exitCodeGet;
          delete globalThis.__swiftjs_exitCodeSet;
        })();
        """#)

        // Stdin is wired last so the `Object.defineProperty(process,
        // …)` call inside it has `process` already bound on
        // `globalThis`. (The stream classes it depends on are
        // installed lazily on first read.)
        installProcessStdin(on: process)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length - 5 JS env-bridges plus the Proxy
    private func installEnvProxy(on process: JSValue) {
        let envGet = block { [weak self] args in
            guard let key = args.first?.toString() else { return nil }
            if Shell.current !== Shell.processDefault {
                return Shell.current.environment.variables[key]
            }
            return self?.envProvider.get(key)
        }
        let envSet = block { [weak self] args in
            guard args.count >= 2,
                  let key = args[0].toString()
            else { return false }
            let value = args[1]
            if Shell.current !== Shell.processDefault {
                if value.isNull || value.isUndefined {
                    Shell.current.environment.variables.removeValue(forKey: key)
                } else {
                    Shell.current.environment.variables[key] = value.toString() ?? ""
                }
                return true
            }
            if value.isNull || value.isUndefined {
                self?.envProvider.set(key, nil)
            } else {
                self?.envProvider.set(key, value.toString())
            }
            return true
        }
        let envHas = block { [weak self] args in
            guard let key = args.first?.toString() else { return false }
            if Shell.current !== Shell.processDefault {
                return Shell.current.environment.variables[key] != nil
            }
            return self?.envProvider.get(key) != nil
        }
        let envKeys = block { [weak self] _ in
            if Shell.current !== Shell.processDefault {
                return Array(Shell.current.environment.variables.keys)
            }
            return self?.envProvider.allKeys ?? []
        }
        let envDel = block { [weak self] args in
            guard let key = args.first?.toString() else { return false }
            if Shell.current !== Shell.processDefault {
                Shell.current.environment.variables.removeValue(forKey: key)
                return true
            }
            self?.envProvider.set(key, nil)
            return true
        }
        setGlobal("__swiftjs_envGet", envGet)
        setGlobal("__swiftjs_envSet", envSet)
        setGlobal("__swiftjs_envHas", envHas)
        setGlobal("__swiftjs_envKeys", envKeys)
        setGlobal("__swiftjs_envDel", envDel)

        let envProxy = context.evaluateScript(#"""
        new Proxy({}, {
          get(_, key)            { return globalThis.__swiftjs_envGet(String(key)); },
          set(_, key, value)     { return globalThis.__swiftjs_envSet(String(key), value); },
          has(_, key)            { return globalThis.__swiftjs_envHas(String(key)); },
          deleteProperty(_, key) { return globalThis.__swiftjs_envDel(String(key)); },
          ownKeys()              { return globalThis.__swiftjs_envKeys(); },
          getOwnPropertyDescriptor(t, key) {
            const v = globalThis.__swiftjs_envGet(String(key));
            return v === undefined ? undefined
              : { enumerable: true, configurable: true, writable: true, value: v };
          },
        });
        """#)!
        process.setObject(envProxy, forKeyedSubscript: "env")
    }

    private func installPlatformMetadata(on process: JSValue) {
        #if os(macOS)
        process.setObject("darwin", forKeyedSubscript: "platform")
        #elseif os(iOS)
        process.setObject("ios", forKeyedSubscript: "platform")
        #elseif os(Linux)
        process.setObject("linux", forKeyedSubscript: "platform")
        #elseif os(Android)
        process.setObject("android", forKeyedSubscript: "platform")
        #else
        process.setObject("unknown", forKeyedSubscript: "platform")
        #endif

        #if arch(arm64)
        process.setObject("arm64", forKeyedSubscript: "arch")
        #elseif arch(x86_64)
        process.setObject("x64", forKeyedSubscript: "arch")
        #else
        process.setObject("unknown", forKeyedSubscript: "arch")
        #endif

        process.setObject("v22.0.0-swiftjs", forKeyedSubscript: "version")
    }

    private func installPidGetters(on process: JSValue) {
        // process.pid / process.ppid: under a bound Shell, return
        // ``Shell.virtualPID`` (synthetic — defaults to 1) so a
        // sandboxed script never sees the embedder's real PID. Under
        // ``Shell.processDefault`` we keep `getpid()` / `getppid()`
        // so the standalone `swift-js` CLI behaves unchanged.
        let pidGetter = block { _ in
            if Shell.current === Shell.processDefault {
                return Int(getpid())
            }
            return Int(Shell.current.virtualPID)
        }
        let ppidGetter = block { _ in
            if Shell.current === Shell.processDefault {
                return Int(getppid())
            }
            // No virtualPPID concept in ShellKit yet; mirror SwiftScript
            // and return the same virtualPID (parent of `1` is `1`
            // under embedded init-style semantics).
            return Int(Shell.current.virtualPID)
        }
        // Bind getters on the local `process` JSValue directly —
        // `globalThis.process` isn't set until the bottom of this
        // method, so a getter that reads from globalThis would fire
        // too early.
        let installPidProps = context.evaluateScript(#"""
        (function (process, getPid, getPpid) {
          Object.defineProperty(process, "pid",  { get: getPid,  enumerable: true, configurable: true });
          Object.defineProperty(process, "ppid", { get: getPpid, enumerable: true, configurable: true });
        })
        """#)!
        installPidProps.call(withArguments: [process, pidGetter, ppidGetter])
    }

    private func installExitAndCwd(on process: JSValue) {
        let exit = block { [weak self] args in
            guard let self else { return nil }
            let code = args.first?.toInt32() ?? 0
            self.didExit = true
            self.exitCode = code
            // Cancel pending timers so the runloop drains immediately.
            for (_, timer) in self.pendingTimers { timer.cancel() }
            self.pendingTimers.removeAll()
            let exception = JSValue(object: ["__swiftjs_exit": true, "code": code],
                                    in: self.context)
            self.context.exception = exception
            return nil
        }
        process.setObject(exit, forKeyedSubscript: "exit")

        let cwd = block { _ in
            if Shell.current === Shell.processDefault {
                return FileManager.default.currentDirectoryPath
            }
            return Shell.current.environment.workingDirectory
        }
        process.setObject(cwd, forKeyedSubscript: "cwd")

        let chdir = block { [weak self] args in
            guard let path = args.first?.toString() else { return nil }
            // Resolve relative `path` against the current shell-CWD
            // first — Node accepts `process.chdir("./sub")` and
            // expects it to compose with the prior cwd. Storing the
            // raw relative string here would leave the bound CWD
            // unusable for subsequent `fs.*` ops.
            let resolved = resolveAgainstShellCWD(path)
            // Sandbox gate: chdir into a denied region is a write —
            // it would let a script position subsequent relative-path
            // ops anywhere. Surface as a Node-style EACCES.
            do {
                try self?.awaitSync { try await authorizePath(resolved, for: .write) }
            } catch {
                _ = self?.throwSandboxDenial(error, syscall: "chdir", path: path)
                return nil
            }
            if Shell.current === Shell.processDefault {
                _ = FileManager.default.changeCurrentDirectoryPath(resolved)
            }
            Shell.current.environment.workingDirectory = resolved
            return nil
        }
        process.setObject(chdir, forKeyedSubscript: "chdir")

        let hrtime = block { _ in
            let now = DispatchTime.now().uptimeNanoseconds
            return [Int(now / 1_000_000_000), Int(now % 1_000_000_000)]
        }
        process.setObject(hrtime, forKeyedSubscript: "hrtime")
    }

    private func installStdoutStderr(on process: JSValue) {
        // process.stdout.write(string) / .stderr.write(string)
        // — print without an automatic trailing newline.
        let stdoutWrite = block { [weak self] args in
            guard let value = args.first else { return false }
            self?.stdout(JSRuntime.stringFromWritable(value))
            return true
        }
        let stderrWrite = block { [weak self] args in
            guard let value = args.first else { return false }
            self?.stderr(JSRuntime.stringFromWritable(value))
            return true
        }
        let stdoutObj = JSValue(newObjectIn: context)!
        stdoutObj.setObject(stdoutWrite, forKeyedSubscript: "write")
        stdoutObj.setObject(true, forKeyedSubscript: "isTTY")
        process.setObject(stdoutObj, forKeyedSubscript: "stdout")
        let stderrObj = JSValue(newObjectIn: context)!
        stderrObj.setObject(stderrWrite, forKeyedSubscript: "write")
        stderrObj.setObject(true, forKeyedSubscript: "isTTY")
        process.setObject(stderrObj, forKeyedSubscript: "stderr")
    }

    private func installProcessEvents(on process: JSValue) {
        // process.on('event', fn) — only `exit` is honoured.
        let onCallback = block { [weak self] args in
            guard let self, args.count >= 2,
                  let event = args[0].toString()
            else { return nil }
            let listener = args[1]
            if event == "exit" { self.exitListeners.append(listener) }
            // Return process for chaining (Node convention).
            return self.context.objectForKeyedSubscript("process")
        }
        process.setObject(onCallback, forKeyedSubscript: "on")
    }

    private func installExitCodeAccessor() {
        // process.exitCode — getter/setter via Object.defineProperty.
        // Stored on a hidden field; the CLI reads `runtime.exitCode`
        // directly.
        let exitCodeGet = block { [weak self] _ in
            self?.exitCode ?? 0
        }
        let exitCodeSet = block { [weak self] args in
            self?.exitCode = args.first?.toInt32() ?? 0
            return nil
        }
        setGlobal("__swiftjs_exitCodeGet", exitCodeGet)
        setGlobal("__swiftjs_exitCodeSet", exitCodeSet)
    }
}

#endif  // !os(Windows)
