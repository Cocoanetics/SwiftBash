import Foundation
import BashInterpreter
import BashCommandKit



/// Holder for resolve/reject of an async child_process Promise.
/// Mirrors the one in Network.swift; access fenced by the main
/// queue hop in Task.detached's continuation.
private final class ChildPromiseHandles: @unchecked Sendable {
    var resolve: JSValue?
    var reject: JSValue?
}

/// Holder for the JS-side `ChildProcess` and its three streams.
/// Crossed into Task.detached / pipe handlers under the same
/// "main-queue-only access" rule as ``ChildPromiseHandles``.
private final class SpawnHandles: @unchecked Sendable {
    var proc: JSValue?
    var stdoutS: JSValue?
    var stderrS: JSValue?
    var stdinS: JSValue?
}

/// Mutable state shared across the readability handlers, the
/// termination handler, and the `finalize()` closure of
/// `startHostShellSpawn`. All access is fenced by `lock`.
private final class HostSpawnState: @unchecked Sendable {
    let lock = NSLock()
    var stdoutDone = false
    var stderrDone = false
    var processDone = false
    var finalized = false
    var exitStatus: Int32 = 0
}

extension JSRuntime {

    /// Build the `node:child_process` module.
    ///
    /// `execSync` / `spawnSync` / `exec` dispatch on the command
    /// line. If every top-level word is a SwiftBash-registered
    /// command, the line runs in-process via `BashInterpreter`
    /// (no fork). Otherwise it goes through host `/bin/sh`, the
    /// way node's `child_process` does. The decision is automatic
    /// — there are no shell-mode flags.
    func makeChildProcessModule() -> JSValue {
        let cp = JSValue(newObjectIn: context)!

        // execSync(command, options?) → string | Buffer
        let execSync = block { [weak self] args in
            guard let self, let cmd = args.first?.toString() else { return nil }
            let opts: JSValue? = args.count >= 2 ? args[1] : nil
            do {
                try denyProcessIfSandboxed(cmd)
            } catch {
                return self.throwSandboxDenial(error, syscall: "spawn")
            }
            return self.runChildSync(command: cmd, args: nil, opts: opts)
        }
        cp.setObject(execSync, forKeyedSubscript: "execSync")

        // spawnSync(command, args?, options?) → { status, stdout, stderr, ... }
        let spawnSync = block { [weak self] args in
            guard let self, let cmd = args.first?.toString() else { return nil }
            let argsVal: JSValue? = args.count >= 2 ? args[1] : nil
            let opts: JSValue? = args.count >= 3 ? args[2] : nil
            do {
                try denyProcessIfSandboxed(cmd)
            } catch {
                return self.throwSandboxDenial(error, syscall: "spawn")
            }
            let argList = (argsVal?.toArray() as? [String]) ?? []
            return self.spawnChildSync(command: cmd, args: argList, opts: opts)
        }
        cp.setObject(spawnSync, forKeyedSubscript: "spawnSync")

        // spawn(command, args?, options?) → ChildProcess with live
        // stdout/stderr/stdin streams. Non-blocking; chunks arrive on
        // the JS event loop the way node delivers them.
        let spawnImpl = block { [weak self] args in
            guard let self, let cmd = args.first?.toString() else { return nil }
            let argsVal: JSValue? = args.count >= 2 ? args[1] : nil
            let opts: JSValue? = args.count >= 3 ? args[2] : nil
            do {
                try denyProcessIfSandboxed(cmd)
            } catch {
                return self.throwSandboxDenial(error, syscall: "spawn")
            }
            let argList = (argsVal?.toArray() as? [String]) ?? []
            return self.runChildSpawn(command: cmd, args: argList, opts: opts)
        }
        cp.setObject(spawnImpl, forKeyedSubscript: "spawn")

        // exec(command, opts?) → Promise<{stdout, stderr, code}>.
        //
        // Non-blocking. Each call spawns a Swift Task.detached that
        // runs an independent BashInterpreter Shell, so N concurrent
        // exec() calls really do run in parallel — Promise.all([exec,
        // exec, exec]) of three `sleep 0.1` commands wall-clocks at
        // ~0.1s, not ~0.3s.
        let exec = block { [weak self] args in
            guard let self, let cmd = args.first?.toString() else { return nil }
            let opts: JSValue? = args.count >= 2 ? args[1] : nil
            do {
                try denyProcessIfSandboxed(cmd)
            } catch {
                return self.throwSandboxDenial(error, syscall: "spawn")
            }
            return self.runChildAsync(command: cmd, opts: opts)
        }
        cp.setObject(exec, forKeyedSubscript: "exec")

        return cp
    }

    /// `spawn(cmd, args)` — non-blocking, returns a ``ChildProcess``
    /// with live `stdout`/`stderr` ``Readable`` streams and a `stdin`
    /// ``Writable``. Each chunk produced by the underlying backend
    /// hops to main and is `_push`ed into the corresponding JS
    /// stream; the `'exit'` and `'close'` events fire when the
    /// command terminates and both output streams have ended.
    ///
    /// Backed by ``Shell`` (`.inProcess`) or `Process` (`.hostShell`),
    /// the same way `execSync` and `exec` are.
    private func runChildSpawn(command: String, args: [String], opts _: JSValue?) -> JSValue? {
        installStreamClasses()
        let ctx = context

        // Build the JS-side ChildProcess + its three streams. Using
        // a small JS factory is simpler than constructing them piece
        // by piece from Swift (we'd otherwise need to manually wire
        // the EventEmitter prototype chain).
        let factory = #"""
        (() => {
          const S = globalThis.__swiftjs_stream;
          const events = (() => {
            const cache = globalThis.__swiftjs_module_cache;
            return cache && cache["events"] ? cache["events"] : require("node:events");
          })();
          const EventEmitter = events.EventEmitter ?? events;
          class ChildProcess extends EventEmitter {}
          const proc = new ChildProcess();
          proc.stdout = new S.Readable();
          proc.stderr = new S.Readable();
          proc.stdin  = new S.Writable();
          proc.killed = false;
          proc.exitCode = null;
          proc.signalCode = null;
          return proc;
        })();
        """#
        guard let proc = ctx.evaluateScript(factory) else { return nil }

        let handles = SpawnHandles()
        handles.proc = proc
        handles.stdoutS = proc.objectForKeyedSubscript("stdout")
        handles.stderrS = proc.objectForKeyedSubscript("stderr")
        handles.stdinS  = proc.objectForKeyedSubscript("stdin")

        // Sentinel keeps the runloop alive until the spawned process
        // closes — same trick `runChildAsync` uses for exec().
        let sentinelID = nextTimerID
        nextTimerID += 1
        let sentinel = DispatchSource.makeTimerSource(queue: .main)
        sentinel.schedule(deadline: .distantFuture)
        sentinel.setEventHandler {}
        pendingTimers[sentinelID] = sentinel
        sentinel.resume()

        switch childShell {
        case .inProcess:
            startInProcessSpawn(command: command, args: args,
                                handles: handles, sentinelID: sentinelID)
        case .hostShell:
            startHostShellSpawn(command: command, args: args,
                                handles: handles, sentinelID: sentinelID)
        }
        return proc
    }

    /// In-process backend for `spawn`. Drives a fresh ``Shell`` whose
    /// stdout/stderr ``OutputSink``s feed into the JS-side
    /// ``Readable`` streams. Stdin is an ``InputSource`` over an
    /// `AsyncStream<Data>` that the JS-side ``Writable`` yields into.
    private func startInProcessSpawn(
        command: String, args: [String],
        handles: SpawnHandles, sentinelID: Int
    ) {
        // Feed stdin: JS Writable -> AsyncStream<Data> -> InputSource.
        let (stdinStream, stdinCont) = AsyncStream<Data>.makeStream()
        wireStdinHooks(stream: handles.stdinS,
                       onWrite: { stdinCont.yield($0) },
                       onEnd:   { stdinCont.finish() })

        let line = Self.composeCommandLine(command, args: args)

        Task.detached { [weak self] in
            let shell = Shell()
            shell.registerStandardCommands()
            let stdoutSink = OutputSink()
            let stderrSink = OutputSink()
            shell.stdout = stdoutSink
            shell.stderr = stderrSink
            shell.stdin = InputSource(bytes: stdinStream)

            async let outDrain: () = Self.drainSinkToJS(stdoutSink, target: handles.stdoutS)
            async let errDrain: () = Self.drainSinkToJS(stderrSink, target: handles.stderrS)

            var status: Int32 = 0
            do {
                let exit = try await shell.run(line)
                stdoutSink.finish()
                stderrSink.finish()
                status = Int32(exit.code)
            } catch {
                let msg = String(describing: error) + "\n"
                stdoutSink.finish()
                stderrSink.write(msg)
                stderrSink.finish()
                status = 1
            }
            await outDrain
            await errDrain

            // Bind the loop's `var status` and the outer-closure's
            // `var self` (from `[weak self]`) into local lets so
            // the inner `MainActor.run` closure captures stable
            // values — Swift 6 strict concurrency rejects capturing
            // `var` directly across the @Sendable boundary.
            let finalStatus = status
            let runtime = self
            await MainActor.run {
                Self.finalizeSpawn(runtime: runtime, handles: handles,
                                   sentinelID: sentinelID,
                                   status: finalStatus)
            }
        }
    }

    /// Host-shell backend for `spawn`. Uses Foundation's `Process`
    /// with three pipes; readability handlers hop chunks back to
    /// main where the JS streams live.
    ///
    /// Unavailable on iOS / tvOS / watchOS (App Sandbox blocks fork);
    /// on those platforms we synthesize an immediate error path.
    private func startHostShellSpawn(
        command: String, args: [String],
        handles: SpawnHandles, sentinelID: Int
    ) {
        #if os(macOS) || os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.composeCommandLine(command, args: args)]

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe
        process.standardInput  = inPipe

        // Feed stdin from the JS Writable straight into the pipe.
        wireStdinHooks(
            stream: handles.stdinS,
            onWrite: { data in
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
            },
            onEnd: {
                try? inPipe.fileHandleForWriting.close()
            }
        )

        // Holder for the host-shell spawn's three "done" flags plus
        // the one-shot `finalized` latch and the captured exit
        // status. Wrapped in a class so the multiple `@Sendable`
        // closures below (readability handlers, termination handler)
        // can share state by reference instead of capturing a heap
        // of local `var`s — Swift 6 rejects the latter.
        //
        // `@unchecked Sendable` because every mutation goes through
        // `lock`; nothing reads or writes any field outside that.
        let state = HostSpawnState()
        let runtime = self
        let finalize: @Sendable () -> Void = {
            state.lock.lock()
            let shouldFire = state.stdoutDone && state.stderrDone
                && state.processDone && !state.finalized
            if shouldFire { state.finalized = true }
            let status = state.exitStatus
            state.lock.unlock()
            guard shouldFire else { return }
            DispatchQueue.main.async {
                Self.finalizeSpawn(runtime: runtime, handles: handles,
                                   sentinelID: sentinelID, status: status)
            }
        }

        Self.installReadabilityHandler(
            on: outPipe.fileHandleForReading,
            target: handles.stdoutS,
            onEOF: {
                state.lock.lock()
                state.stdoutDone = true
                state.lock.unlock()
                finalize()
            }
        )
        Self.installReadabilityHandler(
            on: errPipe.fileHandleForReading,
            target: handles.stderrS,
            onEOF: {
                state.lock.lock()
                state.stderrDone = true
                state.lock.unlock()
                finalize()
            }
        )

        process.terminationHandler = { proc in
            state.lock.lock()
            state.processDone = true
            state.exitStatus = proc.terminationStatus
            state.lock.unlock()
            finalize()
        }

        do {
            try process.run()
        } catch {
            // Fail synthetically: write the message to stderr, mark
            // status 127, end both streams. Run on main so the JS
            // side sees coherent ordering.
            let message = "\(error.localizedDescription)\n"
            DispatchQueue.main.async { [weak self] in
                if let stream = handles.stderrS {
                    Self.pushBytes(Array(message.utf8), to: stream)
                    stream.invokeMethod("_end", withArguments: [])
                }
                handles.stdoutS?.invokeMethod("_end", withArguments: [])
                Self.finalizeSpawn(runtime: self, handles: handles,
                                   sentinelID: sentinelID, status: 127)
            }
        }
        #else
        let message = "host shell unavailable on this platform\n"
        DispatchQueue.main.async { [weak self] in
            if let stream = handles.stderrS {
                Self.pushBytes(Array(message.utf8), to: stream)
                stream.invokeMethod("_end", withArguments: [])
            }
            handles.stdoutS?.invokeMethod("_end", withArguments: [])
            Self.finalizeSpawn(runtime: self, handles: handles,
                               sentinelID: sentinelID, status: 127)
        }
        #endif
    }

    /// Hook the JS-side ``Writable`` so that `write(chunk)` and
    /// `end()` invoke the supplied closures. Chunks are decoded
    /// through ``Self/dataFromChunk`` first.
    private func wireStdinHooks(
        stream: JSValue?,
        onWrite: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) {
        guard let stream else { return }
        let writeImpl = block { args in
            if let chunk = args.first {
                onWrite(JSRuntime.dataFromChunk(chunk))
            }
            return nil
        }
        let endImpl = block { _ in
            onEnd()
            return nil
        }
        stream.setObject(writeImpl, forKeyedSubscript: "_onWrite")
        stream.setObject(endImpl, forKeyedSubscript: "_onEnd")
    }

    /// Drain an ``OutputSink`` until it finishes, hopping to main on
    /// every chunk to push it into the JS-side ``Readable``. Sends a
    /// final `_end()` once the stream completes.
    private static func drainSinkToJS(_ sink: OutputSink,
                                      target: JSValue?) async {
        for await chunk in sink.bytes {
            let bytes = Array(chunk)
            await MainActor.run {
                guard let target else { return }
                Self.pushBytes(bytes, to: target)
            }
        }
        await MainActor.run {
            _ = target?.invokeMethod("_end", withArguments: [])
        }
    }

    /// Wire a `FileHandle.readabilityHandler` to forward bytes to the
    /// JS-side ``Readable``. Empty Data signals EOF — at which point
    /// we tear down the handler, push a final `_end`, and call
    /// `onEOF` so the caller can sequence the `close` event.
    #if os(macOS) || os(Linux)
    private static func installReadabilityHandler(
        on fh: FileHandle,
        target: JSValue?,
        onEOF: @escaping @Sendable () -> Void
    ) {
        fh.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                DispatchQueue.main.async {
                    target?.invokeMethod("_end", withArguments: [])
                }
                onEOF()
                return
            }
            let bytes = Array(data)
            DispatchQueue.main.async {
                if let target {
                    Self.pushBytes(bytes, to: target)
                }
            }
        }
    }
    #endif

    /// Push raw bytes into a JS-side ``Readable`` as a Buffer. Must
    /// be called on the main queue.
    private static func pushBytes(_ bytes: [UInt8], to stream: JSValue) {
        let ctx = stream.context
        guard let bufCtor = ctx.objectForKeyedSubscript("Buffer"),
              let buf = bufCtor.invokeMethod("from", withArguments: [bytes])
        else { return }
        stream.invokeMethod("_push", withArguments: [buf])
    }

    /// Cancel the sentinel timer, set `exitCode`/`signalCode`, and
    /// emit `'exit'` then `'close'` on the JS-side ChildProcess.
    /// Must run on the main queue (touches JSValues + the runtime's
    /// timer table).
    private static func finalizeSpawn(
        runtime: JSRuntime?,
        handles: SpawnHandles,
        sentinelID: Int,
        status: Int32
    ) {
        if let runtime,
           let timer = runtime.pendingTimers.removeValue(forKey: sentinelID) {
            timer.cancel()
        }
        // Close the stdin Writable so its `writable` flag flips to
        // false and further `write()` calls are no-ops. Without this,
        // user code that keeps writing after the child exited would
        // either silently drop bytes into a closed pipe (`.hostShell`)
        // or grow the stdin AsyncStream buffer unbounded
        // (`.inProcess`). `Writable.end()` is idempotent, so it's
        // safe even when the user already called it themselves.
        if let stdin = handles.stdinS, !stdin.isUndefined, !stdin.isNull {
            _ = stdin.invokeMethod("end", withArguments: [])
        }
        guard let proc = handles.proc, !proc.isUndefined, !proc.isNull else { return }
        proc.setObject(status, forKeyedSubscript: "exitCode" as NSString)
        // Match node: signal === null when the process exited normally.
        proc.setObject(NSNull(), forKeyedSubscript: "signalCode" as NSString)
        _ = proc.invokeMethod("emit", withArguments: ["exit", status, NSNull()])
        _ = proc.invokeMethod("emit", withArguments: ["close", status, NSNull()])
    }

    /// Convert a JS-side chunk (string | Buffer | Uint8Array | array
    /// of bytes) to a `Data`. Used by stdin writes from JS.
    static func dataFromChunk(_ value: JSValue) -> Data {
        if value.isString {
            return Data((value.toString() ?? "").utf8)
        }
        if let arr = value.toArray() as? [NSNumber] {
            return Data(arr.map { $0.uint8Value })
        }
        return Data((value.toString() ?? "").utf8)
    }

    /// Async `exec`. Spawns a detached Task that runs the command
    /// through SwiftBash's interpreter (or `/bin/sh` if requested).
    /// Returns a Promise that resolves on success and rejects on
    /// non-zero exit. A sentinel timer keeps the JSRuntime runloop
    /// alive until the Promise settles.
    private func runChildAsync(command: String, opts _: JSValue?) -> JSValue {
        let useHostShell = (childShell == .hostShell)
        let ctx = context
        let handles = ChildPromiseHandles()

        let handlerJS = block { args in
            if args.count >= 2 {
                handles.resolve = args[0]
                handles.reject = args[1]
            }
            return nil
        }
        let promiseClass = ctx.objectForKeyedSubscript("Promise")!
        let promise = promiseClass.construct(withArguments: [handlerJS])!

        // Sentinel keeps drainPendingWorkIfNeeded looping.
        let sentinelID = nextTimerID
        nextTimerID += 1
        let sentinel = DispatchSource.makeTimerSource(queue: .main)
        sentinel.schedule(deadline: .distantFuture)
        sentinel.setEventHandler {}
        pendingTimers[sentinelID] = sentinel
        sentinel.resume()

        Task.detached { [weak self] in
            let result: ChildResult
            if useHostShell {
                result = await Self.runHostShellAsync(command: command, args: nil)
            } else {
                result = await Self.runBashInterpreterAsync(command: command)
            }
            // Re-capture `self` weakly for the inner `MainActor.run`
            // closure — capturing it from the outer `[weak self]` var
            // would warn under Swift 6 strict concurrency.
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let s = self.pendingTimers.removeValue(forKey: sentinelID) {
                    s.cancel()
                }
                if result.status == 0 {
                    let payload = JSValue(newObjectIn: self.context)!
                    payload.setObject(result.stdout,
                                      forKeyedSubscript: "stdout" as NSString)
                    payload.setObject(result.stderr,
                                      forKeyedSubscript: "stderr" as NSString)
                    payload.setObject(result.status,
                                      forKeyedSubscript: "code" as NSString)
                    handles.resolve?.call(withArguments: [payload])
                } else {
                    // Node's `exec` populates the rejected Error with
                    // both the numeric exit code (`code`) and a more
                    // structured shape: `cmd`, `killed`, `signal`,
                    // `stdout`, `stderr`. Match that surface so error
                    // matchers in user code can use `err.code === 127`
                    // / `err.cmd` etc.
                    let trimmedStderr = result.stderr
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = trimmedStderr.isEmpty ? "" : "\n\(trimmedStderr)"
                    let err = self.makeJSError(
                        "Command failed: \(command)\(suffix)",
                        in: self.context,
                        extras: [
                            "code": result.status,
                            "status": result.status,
                            "cmd": command,
                            "killed": false,
                            "signal": NSNull(),
                            "stdout": result.stdout,
                            "stderr": result.stderr,
                        ]
                    )
                    handles.reject?.call(withArguments: [err])
                }
            }
        }

        return promise
    }

    /// Static async variant of runBashInterpreter — no semaphore,
    /// returns the result via async/await so multiple instances
    /// can be in flight at once.
    private static func runBashInterpreterAsync(command: String) async -> ChildResult {
        let shell = Shell()
        shell.registerStandardCommands()
        shell.stdout = OutputSink()
        shell.stderr = OutputSink()
        let stdoutSink = shell.stdout
        let stderrSink = shell.stderr

        async let outDrain: String = stdoutSink.readAllString()
        async let errDrain: String = stderrSink.readAllString()

        var status: Int32 = 0
        var extraErr = ""
        do {
            let exit = try await shell.run(command)
            stdoutSink.finish()
            stderrSink.finish()
            status = Int32(exit.code)
        } catch {
            stdoutSink.finish()
            stderrSink.finish()
            extraErr = String(describing: error) + "\n"
            status = 1
        }
        return await ChildResult(
            status: status,
            stdout: outDrain,
            stderr: extraErr + errDrain
        )
    }

    /// Static async variant of runHostShell — uses Process and a
    /// continuation rather than a blocking `waitUntilExit` so the
    /// caller doesn't peg a thread.
    ///
    /// `Foundation.Process` is unavailable on iOS / tvOS / watchOS
    /// (App Sandbox can't fork). On those platforms we return a
    /// 127 with a clear message — `JSRuntime.childShell == .hostShell`
    /// shouldn't be reachable there anyway, but the function still
    /// has to compile.
    private static func runHostShellAsync(command: String, args: [String]?) async -> ChildResult {
        #if os(macOS) || os(Linux)
        return await withCheckedContinuation { (cont: CheckedContinuation<ChildResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            if let args, !args.isEmpty {
                process.arguments = ["-c", command + " " + args.map { "\"\($0)\"" }.joined(separator: " ")]
            } else {
                process.arguments = ["-c", command]
            }
            let outPipe = Pipe(); let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError  = errPipe
            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: ChildResult(
                    status: proc.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
            do {
                try process.run()
            } catch {
                cont.resume(returning: ChildResult(
                    status: 127, stdout: "", stderr: error.localizedDescription
                ))
            }
        }
        #else
        return ChildResult(
            status: 127, stdout: "",
            stderr: "host shell unavailable on this platform"
        )
        #endif
    }

    /// `execSync`: run a command line through bash, return stdout.
    /// In Node, default encoding is `null` (returns Buffer); we
    /// default to utf-8 string to match the shell-script idiom.
    private func runChildSync(command: String, args _: [String]?, opts: JSValue?) -> Any? {
        let encoding = optsEncoding(opts) ?? "utf-8"
        let result = pickBackendAndRun(command: command, args: nil, opts: opts)

        if result.status != 0 {
            // Match the shape Node throws from execSync — Error with
            // `status`, `stdout`, `stderr`, `pid`, `signal`, plus a
            // numeric `code` mirroring `status`. The string form keeps
            // Node's "Command failed: <cmd>\n<stderr>" message so
            // existing log-grep'ing code keeps working.
            let trimmedStderr = result.stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = trimmedStderr.isEmpty ? "" : "\n\(trimmedStderr)"
            return throwJSError(
                "Command failed: \(command)\(suffix)",
                extras: [
                    "code": result.status,
                    "status": result.status,
                    "cmd": command,
                    "signal": NSNull(),
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                ]
            )
        }
        return encode(bytes: Array(result.stdout.utf8), encoding: encoding)
    }

    /// spawnSync: returns `{ status, stdout, stderr, signal, error }`.
    /// Doesn't throw on non-zero exit (matches Node).
    private func spawnChildSync(command: String, args: [String], opts: JSValue?) -> Any? {
        let result = pickBackendAndRun(command: command, args: args, opts: opts)

        let ctx = context
        let obj = JSValue(newObjectIn: ctx)!
        obj.setObject(result.status, forKeyedSubscript: "status" as NSString)
        let bufCtor = ctx.objectForKeyedSubscript("Buffer")!
        obj.setObject(bufCtor.invokeMethod("from", withArguments: [Array(result.stdout.utf8)])!,
                      forKeyedSubscript: "stdout" as NSString)
        obj.setObject(bufCtor.invokeMethod("from", withArguments: [Array(result.stderr.utf8)])!,
                      forKeyedSubscript: "stderr" as NSString)
        obj.setObject(NSNull(), forKeyedSubscript: "signal" as NSString)
        obj.setObject(NSNull(), forKeyedSubscript: "error" as NSString)
        return obj
    }

    private struct ChildResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Run the command through SwiftBash's in-process interpreter.
    /// No fork/exec — the bash AST executes inside this Swift binary.
    private func runBashInterpreter(command: String) -> ChildResult {
        // Block this thread until the async run finishes. JS execSync
        // is synchronous by contract, so we have to wait. Note this
        // assumes we're not on the main queue (or that nothing on the
        // main queue is also waiting on this) — for shebang scripts
        // run from a CLI, that's fine.
        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        var stdoutText = ""
        var stderrText = ""

        Task.detached {
            let shell = Shell()
            shell.registerStandardCommands()

            // Capture stdout/stderr into local buffers.
            shell.stdout = OutputSink()
            shell.stderr = OutputSink()
            let stdoutSink = shell.stdout
            let stderrSink = shell.stderr

            // Drain both sinks in parallel with the run.
            async let outDrain: String = stdoutSink.readAllString()
            async let errDrain: String = stderrSink.readAllString()

            do {
                let exit = try await shell.run(command)
                stdoutSink.finish()
                stderrSink.finish()
                status = Int32(exit.code)
            } catch {
                stdoutSink.finish()
                stderrSink.finish()
                stderrText += String(describing: error) + "\n"
                status = 1
            }
            stdoutText = await outDrain
            stderrText += await errDrain
            semaphore.signal()
        }

        semaphore.wait()
        return ChildResult(status: status, stdout: stdoutText, stderr: stderrText)
    }

    /// Foundation Process backend — spawns a real /bin/sh subprocess.
    /// `Process` is unavailable on iOS / tvOS / watchOS (App Sandbox);
    /// gated so the file still compiles on those platforms.
    private func runHostShell(command: String, args: [String]?) -> ChildResult {
        #if os(macOS) || os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        if let args, !args.isEmpty {
            process.arguments = ["-c", command + " " + args.map { "\"\($0)\"" }.joined(separator: " ")]
        } else {
            process.arguments = ["-c", command]
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ChildResult(status: 127, stdout: "", stderr: error.localizedDescription)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ChildResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
        #else
        return ChildResult(
            status: 127, stdout: "",
            stderr: "host shell unavailable on this platform"
        )
        #endif
    }

    /// Static dispatch on the runtime's configured backend.
    /// `.inProcess` → BashInterpreter only (unknown commands fail
    /// like normal bash). `.hostShell` → fork `/bin/sh`.
    private func pickBackendAndRun(command: String, args: [String]?, opts _: JSValue?) -> ChildResult {
        switch childShell {
        case .inProcess:
            // spawnSync('cmd', ['a','b']) needs to act as `cmd a b`.
            // BashInterpreter takes a single command-line string, so
            // join the argv with shell-safe quoting.
            return runBashInterpreter(command: Self.composeCommandLine(command, args: args))
        case .hostShell:
            return runHostShell(command: command, args: args)
        }
    }

    /// Combine `(command, args)` into a single shell-safe command
    /// line. Each arg is single-quoted (with embedded `'` escaped
    /// as `'\''`), the bash-conventional way to pass a literal arg
    /// through a shell parser.
    private static func composeCommandLine(_ command: String, args: [String]?) -> String {
        guard let args, !args.isEmpty else { return command }
        let quoted = args.map { arg -> String in
            "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return command + " " + quoted.joined(separator: " ")
    }

    private func optsEncoding(_ opts: JSValue?) -> String? {
        guard let opts, opts.isObject,
              let enc = opts.objectForKeyedSubscript("encoding"),
              enc.isString else { return nil }
        return enc.toString()
    }

    private func encode(bytes: [UInt8], encoding: String) -> Any? {
        switch encoding.lowercased() {
        case "utf-8", "utf8":
            return String(decoding: bytes, as: UTF8.self)
        case "buffer":
            let bufCtor = context.objectForKeyedSubscript("Buffer")!
            return bufCtor.invokeMethod("from", withArguments: [bytes])!
        default:
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
