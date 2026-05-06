import Foundation
import JavaScriptCore
import BashInterpreter
import BashCommandKit

extension JSRuntime {

    /// Build the `node:child_process` module.
    ///
    /// `execSync` and `spawnSync` route through the SwiftBash
    /// in-process interpreter by default, so a JS script can run
    /// bash pipelines without the OS spawning a separate process.
    /// Pass `{ shell: 'host' }` (or set the `SWIFTJS_HOST_SHELL=1`
    /// env var) to fall back to Foundation's `Process`.
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

        return cp
    }

    /// `execSync`: run a command line through bash, return stdout.
    /// In Node, default encoding is `null` (returns Buffer); we
    /// default to utf-8 string to match the shell-script idiom.
    private func runChildSync(command: String, args _: [String]?, opts: JSValue?) -> Any? {
        let useHostShell = optsUseHostShell(opts)
        let encoding = optsEncoding(opts) ?? "utf-8"

        let result: ChildResult
        if useHostShell {
            result = runHostShell(command: command, args: nil)
        } else {
            result = runBashInterpreter(command: command)
        }

        if result.status != 0 {
            return throwJS("Command failed: \(command)\n\(result.stderr)")
        }
        return encode(bytes: Array(result.stdout.utf8), encoding: encoding)
    }

    /// spawnSync: returns `{ status, stdout, stderr, signal, error }`.
    /// Doesn't throw on non-zero exit (matches Node).
    private func spawnChildSync(command: String, args: [String], opts: JSValue?) -> Any? {
        let useHostShell = optsUseHostShell(opts)
        let result: ChildResult
        if useHostShell || !args.isEmpty {
            // Bash-style "command args..." mapping is awkward — when
            // the caller hands us argv, run it through host
            // Process so quoting matches expectations.
            result = runHostShell(command: command, args: args)
        } else {
            result = runBashInterpreter(command: command)
        }

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
    private func runHostShell(command: String, args: [String]?) -> ChildResult {
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
    }

    private func optsUseHostShell(_ opts: JSValue?) -> Bool {
        if ProcessInfo.processInfo.environment["SWIFTJS_HOST_SHELL"] == "1" {
            return true
        }
        guard let opts, opts.isObject,
              let shell = opts.objectForKeyedSubscript("shell"),
              shell.isString else { return false }
        return shell.toString() == "host"
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
