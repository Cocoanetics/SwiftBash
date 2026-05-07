import Foundation
import BashInterpreter
import BashCommandKit

#if canImport(JavaScriptCore)

import JavaScriptCore

/// Holder for resolve/reject of an async child_process Promise.
/// Mirrors the one in Network.swift; access fenced by the main
/// queue hop in Task.detached's continuation.
private final class ChildPromiseHandles: @unchecked Sendable {
    var resolve: JSValue?
    var reject: JSValue?
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
        let execSync: @convention(block) (String, JSValue?) -> Any? = { [weak self] cmd, opts in
            guard let self else { return nil }
            return self.runChildSync(command: cmd, args: nil, opts: opts)
        }
        cp.setObject(block(execSync as AnyObject),
                     forKeyedSubscript: "execSync" as NSString)

        // spawnSync(command, args?, options?) → { status, stdout, stderr, ... }
        let spawnSync: @convention(block) (String, JSValue?, JSValue?) -> Any? = { [weak self] cmd, args, opts in
            guard let self else { return nil }
            let argList = (args?.toArray() as? [String]) ?? []
            return self.spawnChildSync(command: cmd, args: argList, opts: opts)
        }
        cp.setObject(block(spawnSync as AnyObject),
                     forKeyedSubscript: "spawnSync" as NSString)

        // exec(command, opts?) → Promise<{stdout, stderr, code}>.
        //
        // Non-blocking. Each call spawns a Swift Task.detached that
        // runs an independent BashInterpreter Shell, so N concurrent
        // exec() calls really do run in parallel — Promise.all([exec,
        // exec, exec]) of three `sleep 0.1` commands wall-clocks at
        // ~0.1s, not ~0.3s.
        let exec: @convention(block) (String, JSValue?) -> JSValue? = { [weak self] cmd, opts in
            guard let self else { return nil }
            return self.runChildAsync(command: cmd, opts: opts)
        }
        cp.setObject(block(exec as AnyObject),
                     forKeyedSubscript: "exec" as NSString)

        return cp
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

        let handler: @convention(block) (JSValue, JSValue) -> Void = { resolve, reject in
            handles.resolve = resolve
            handles.reject = reject
        }
        let handlerJS = JSValue(object: block(handler as AnyObject), in: ctx)!
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
            await MainActor.run {
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
        #if os(macOS) || os(Linux) || os(Windows)
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
        #if os(macOS) || os(Linux) || os(Windows)
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
#endif
