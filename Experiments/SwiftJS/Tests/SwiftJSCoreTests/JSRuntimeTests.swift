import XCTest
@testable import SwiftJSCore
import BashInterpreter
import BashCommandKit

#if canImport(JavaScriptCore)

final class JSRuntimeTests: XCTestCase {

    private func runtime() -> (JSRuntime, () -> String, () -> String) {
        var out = ""
        var err = ""
        let r = JSRuntime(
            argv: ["swift-js", "test.js", "alpha", "beta"],
            env: ["FOO": "bar"],
            stdout: { out += $0 },
            stderr: { err += $0 }
        )
        return (r, { out }, { err })
    }

    // MARK: - basics

    func testBasicArithmetic() {
        let (r, _, _) = runtime()
        XCTAssertEqual(r.run("1 + 2 + 3")?.toInt32(), 6)
    }

    func testConsoleLog() {
        let (r, out, _) = runtime()
        r.run("console.log('hi', 1, {a:2})")
        XCTAssertEqual(out(), "hi 1 {\"a\":2}\n")
    }

    func testProcessArgvAndEnv() {
        let (r, out, _) = runtime()
        r.run("console.log(process.argv[2], process.env.FOO)")
        XCTAssertEqual(out(), "alpha bar\n")
    }

    func testProcessExitSetsCode() {
        let (r, _, _) = runtime()
        r.run("process.exit(7)")
        XCTAssertEqual(r.exitCode, 7)
    }

    func testUnhandledThrowSetsExitCode() {
        let (r, _, err) = runtime()
        r.run("throw new Error('boom')")
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(err().contains("boom"))
    }

    func testShebangIsStripped() {
        let (r, out, _) = runtime()
        let src = "#!/usr/bin/env swift-js\nconsole.log('after-shebang')\n"
        r.run(src, name: "shebang.js")
        XCTAssertEqual(out(), "after-shebang\n")
    }

    // MARK: - require + builtin modules

    func testRequireFsRoundTrip() throws {
        let (r, out, _) = runtime()
        let tmp = NSTemporaryDirectory() + "swiftjs-rt-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        r.run(#"""
        const fs = require('node:fs');
        fs.writeFileSync("\#(tmp)", "hello world");
        const back = fs.readFileSync("\#(tmp)", "utf-8");
        console.log(back, fs.existsSync("\#(tmp)"));
        """#)
        XCTAssertEqual(out(), "hello world true\n")
    }

    func testRequireBareAndPrefixedAreSame() {
        let (r, out, _) = runtime()
        r.run("console.log(require('fs') === require('node:fs'))")
        XCTAssertEqual(out(), "true\n")
    }

    func testPathModule() {
        let (r, out, _) = runtime()
        r.run("""
        const path = require('node:path');
        console.log(path.join('a','b','c.txt'));
        console.log(path.basename('/x/y/z.js'));
        console.log(path.dirname('/x/y/z.js'));
        console.log(path.extname('z.js'));
        console.log(path.isAbsolute('/foo'), path.isAbsolute('foo'));
        """)
        XCTAssertEqual(out(), "a/b/c.txt\nz.js\n/x/y\n.js\ntrue false\n")
    }

    func testOsModule() {
        let (r, out, _) = runtime()
        r.run("""
        const os = require('node:os');
        console.log(typeof os.homedir(), typeof os.tmpdir(), os.EOL === '\\n');
        """)
        XCTAssertEqual(out(), "string string true\n")
    }

    func testFsStatSync() {
        let (r, out, _) = runtime()
        r.run("""
        const fs = require('fs');
        const s = fs.statSync('/tmp');
        console.log(s.isDirectory(), s.isFile());
        """)
        XCTAssertEqual(out(), "true false\n")
    }

    func testRequireUnknownModuleThrows() {
        let (r, _, err) = runtime()
        r.run("require('this-does-not-exist')")
        XCTAssertTrue(err().contains("Cannot find module"))
        XCTAssertEqual(r.exitCode, 1)
    }

    func testLocalFileRequire() throws {
        let (r, out, _) = runtime()
        let dir = NSTemporaryDirectory() + "swiftjs-mod-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let helper = dir + "helper.js"
        try "module.exports = { greet: (n) => 'hi, ' + n };".write(toFile: helper, atomically: true, encoding: .utf8)
        let main = dir + "main.js"
        try "const h = require('./helper'); console.log(h.greet('world'));"
            .write(toFile: main, atomically: true, encoding: .utf8)
        try r.runFile(main)
        XCTAssertEqual(out(), "hi, world\n")
    }

    // MARK: - Buffer + encoding

    func testBufferFromStringAndToString() {
        let (r, out, _) = runtime()
        r.run("""
        const b = Buffer.from('hello, 世界');
        console.log(b.length, b.toString('utf-8'));
        console.log(b.toString('hex'));
        console.log(b.toString('base64'));
        """)
        // utf-8 byte length of 'hello, ' (7) + '世' (3) + '界' (3) = 13
        XCTAssertEqual(out(),
            "13 hello, 世界\n68656c6c6f2c20e4b896e7958c\naGVsbG8sIOS4lueVjA==\n")
    }

    func testBufferFromHexAndBase64() {
        let (r, out, _) = runtime()
        r.run("""
        const a = Buffer.from('48656c6c6f', 'hex').toString();
        const b = Buffer.from('aGVsbG8=', 'base64').toString();
        console.log(a, b);
        """)
        XCTAssertEqual(out(), "Hello hello\n")
    }

    func testBufferIsUint8Array() {
        let (r, out, _) = runtime()
        r.run("""
        const b = Buffer.from([1,2,3]);
        console.log(b instanceof Uint8Array, Buffer.isBuffer(b), b.length);
        """)
        XCTAssertEqual(out(), "true true 3\n")
    }

    func testFsReadFileWithoutEncodingReturnsBuffer() throws {
        let (r, out, _) = runtime()
        let tmp = NSTemporaryDirectory() + "swiftjs-buf-\(UUID().uuidString).bin"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "abc".write(toFile: tmp, atomically: true, encoding: .utf8)
        r.run(#"""
        const fs = require('fs');
        const buf = fs.readFileSync("\#(tmp)");
        console.log(Buffer.isBuffer(buf), buf.length, buf.toString());
        """#)
        XCTAssertEqual(out(), "true 3 abc\n")
    }

    // MARK: - Web globals

    func testTextEncoderRoundTrip() {
        let (r, out, _) = runtime()
        r.run("""
        const enc = new TextEncoder();
        const dec = new TextDecoder();
        const bytes = enc.encode('hi 🎉');
        console.log(bytes.length, dec.decode(bytes));
        """)
        // utf-8 length of 'hi ' (3) + '🎉' (4) = 7
        XCTAssertEqual(out(), "7 hi 🎉\n")
    }

    func testAtobBtoa() {
        let (r, out, _) = runtime()
        r.run("""
        console.log(btoa('hello'));
        console.log(atob('aGVsbG8='));
        """)
        XCTAssertEqual(out(), "aGVsbG8=\nhello\n")
    }

    func testURL() {
        let (r, out, _) = runtime()
        r.run("""
        const u = new URL('https://example.com:8080/foo/bar?x=1#h');
        console.log(u.protocol, u.hostname, u.port, u.pathname, u.search, u.hash);
        """)
        XCTAssertEqual(out(), "https: example.com 8080 /foo/bar ?x=1 #h\n")
    }

    func testQueueMicrotask() {
        let (r, out, _) = runtime()
        r.run("""
        queueMicrotask(() => console.log('micro'));
        console.log('sync');
        """)
        // Microtask drains before evaluateScript returns.
        XCTAssertEqual(out(), "sync\nmicro\n")
    }

    // MARK: - Timers

    func testSetTimeoutFires() {
        let (r, out, _) = runtime()
        r.run("setTimeout(() => console.log('late'), 10); console.log('early')")
        XCTAssertEqual(out(), "early\nlate\n")
    }

    func testClearTimeoutCancels() {
        let (r, out, _) = runtime()
        r.run("""
        const id = setTimeout(() => console.log('should-not-fire'), 50);
        clearTimeout(id);
        console.log('done');
        """)
        // Wait long enough that the timer would have fired.
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(out(), "done\n")
    }

    func testSetIntervalAndClear() {
        let (r, out, _) = runtime()
        r.run("""
        let n = 0;
        const id = setInterval(() => {
          n += 1;
          console.log('tick', n);
          if (n >= 3) clearInterval(id);
        }, 5);
        """)
        XCTAssertEqual(out(), "tick 1\ntick 2\ntick 3\n")
    }

    func testProcessExitInsideTimer() {
        let (r, out, _) = runtime()
        r.run("""
        setTimeout(() => process.exit(42), 5);
        setTimeout(() => console.log('should-not-fire'), 50);
        """)
        XCTAssertEqual(r.exitCode, 42)
        XCTAssertFalse(out().contains("should-not-fire"))
    }

    // MARK: - crypto

    func testCryptoSha256Hex() {
        let (r, out, _) = runtime()
        r.run("""
        const c = require('node:crypto');
        console.log(c.createHash('sha256').update('hello').digest('hex'));
        """)
        XCTAssertEqual(out().trimmingCharacters(in: .whitespacesAndNewlines),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testCryptoHmacChainable() {
        let (r, out, _) = runtime()
        r.run("""
        const c = require('crypto');
        console.log(c.createHmac('sha256','key').update('hello').digest('hex'));
        """)
        XCTAssertEqual(out().trimmingCharacters(in: .whitespacesAndNewlines),
            "9307b3b915efb5171ff14d8cb55fbcc798c6c0ef1456d66ded1a6aa723a58b7b")
    }

    func testCryptoRandomBytes() {
        let (r, out, _) = runtime()
        r.run("""
        const c = require('node:crypto');
        const b = c.randomBytes(16);
        console.log(b.length, Buffer.isBuffer(b), b.toString('hex').length);
        """)
        XCTAssertEqual(out(), "16 true 32\n")
    }

    func testCryptoRandomUUID() {
        let (r, out, _) = runtime()
        r.run("""
        const c = require('node:crypto');
        const id = c.randomUUID();
        console.log(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id));
        """)
        XCTAssertEqual(out(), "true\n")
    }

    func testCryptoTimingSafeEqual() {
        let (r, out, _) = runtime()
        r.run("""
        const c = require('node:crypto');
        console.log(
          c.timingSafeEqual(Buffer.from('hello'), Buffer.from('hello')),
          c.timingSafeEqual(Buffer.from('hello'), Buffer.from('world')),
          c.timingSafeEqual(Buffer.from('h'),     Buffer.from('hi'))
        );
        """)
        XCTAssertEqual(out(), "true false false\n")
    }

    // MARK: - child_process (BashInterpreter backend)

    func testExecSyncViaBashInterpreter() {
        let (r, out, _) = runtime()
        r.run("""
        const cp = require('node:child_process');
        // The pipe and tr both run through SwiftBash's in-process
        // interpreter — no fork/exec.
        console.log(cp.execSync('echo hello | tr a-z A-Z').trim());
        """)
        XCTAssertEqual(out(), "HELLO\n")
    }

    func testProcessPid() {
        let (r, out, _) = runtime()
        r.run("console.log(typeof process.pid, process.pid > 0, typeof process.ppid);")
        XCTAssertEqual(out(), "number true number\n")
    }

    func testExecSyncAutoFallbackForExternalBinary() {
        // `git` isn't in SwiftBash's catalog, so auto-mode should
        // route this through the host shell. We don't assume any
        // specific git output — just that execSync didn't throw and
        // returned something non-empty.
        let (r, out, _) = runtime()
        r.run("""
        const cp = require('node:child_process');
        const v = cp.execSync('git --version', { encoding: 'utf-8' });
        console.log(v.startsWith('git'));
        """)
        XCTAssertEqual(out(), "true\n")
    }

    func testExecSyncForceInProcessRejectsExternalBinary() {
        // With shell:'in-process' the SwiftBash interpreter alone
        // serves the request; an unknown command is a hard fail.
        let (r, _, err) = runtime()
        r.run("""
        const cp = require('node:child_process');
        try { cp.execSync('git --version', { shell: 'in-process' }); console.log('UNEXPECTED'); }
        catch (e) { console.error('threw:', e.message.split(String.raw`\n`)[0]); }
        """)
        XCTAssertTrue(err().contains("threw:"))
        XCTAssertTrue(err().contains("Command failed: git"))
    }

    func testExecSyncEchoStringRoundTrip() {
        let (r, out, _) = runtime()
        r.run("""
        const cp = require('child_process');
        const text = cp.execSync('echo "swift-js"');
        console.log(text.trim());
        """)
        XCTAssertEqual(out(), "swift-js\n")
    }

    func testAsyncExecResolvesWithStdout() {
        let (r, out, _) = runtime()
        r.run("""
        const cp = require('node:child_process');
        cp.exec('printf "abc"').then(r => console.log('got:', r.stdout, r.code));
        """)
        XCTAssertEqual(out(), "got: abc 0\n")
    }

    func testAsyncExecRejectsOnNonZeroExit() {
        let (r, out, _) = runtime()
        r.run("""
        const cp = require('node:child_process');
        cp.exec('exit 7')
          .then(_ => console.log('unexpected resolve'))
          .catch(e => console.log('rejected code:', e.code));
        """)
        XCTAssertEqual(out(), "rejected code: 7\n")
    }

    func testAsyncExecParallelism() {
        // Three concurrent sleeps. Wall time should be ~0.1s, not
        // ~0.3s — proves Promise.all dispatches them onto separate
        // Swift Tasks rather than serialising.
        let (r, out, _) = runtime()
        let start = Date()
        r.run("""
        const cp = require('node:child_process');
        Promise.all([
          cp.exec('sleep 0.1; printf 1'),
          cp.exec('sleep 0.1; printf 2'),
          cp.exec('sleep 0.1; printf 3'),
        ]).then(rs => console.log(rs.map(r => r.stdout).join(',')));
        """)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(out(), "1,2,3\n")
        // Allow a generous upper bound for slow CI; sequential
        // would be ~300ms, parallel ~100ms.
        XCTAssertLessThan(elapsed, 0.25, "parallel exec took \(elapsed)s — looks serialised")
    }

    func testSpawnSyncReturnsObject() {
        let (r, out, _) = runtime()
        r.run("""
        const cp = require('child_process');
        const r = cp.spawnSync('echo abc');
        console.log(r.status, Buffer.isBuffer(r.stdout), r.stdout.toString().trim());
        """)
        XCTAssertEqual(out(), "0 true abc\n")
    }

    // MARK: - fs/promises

    func testFsPromisesReadAndWrite() throws {
        let (r, out, _) = runtime()
        let tmp = NSTemporaryDirectory() + "swiftjs-fsp-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        r.run(#"""
        const fs = require('node:fs/promises');
        (async () => {
          await fs.writeFile("\#(tmp)", "async-write");
          const text = await fs.readFile("\#(tmp)", 'utf-8');
          console.log(text);
        })();
        """#)
        XCTAssertEqual(out(), "async-write\n")
    }

    // MARK: - ESM rewriter

    func testEsmExportConst() {
        let (r, out, _) = runtime()
        r.run("""
        export const x = 7;
        console.log("x =", x, "exports.x =", exports.x);
        """)
        XCTAssertEqual(out(), "x = 7 exports.x = 7\n")
    }

    func testEsmExportFunction() {
        let (r, out, _) = runtime()
        r.run("""
        export function greet(n) { return "hi, " + n; }
        console.log(greet("world"), typeof exports.greet);
        """)
        XCTAssertEqual(out(), "hi, world function\n")
    }

    func testEsmExportClass() {
        let (r, out, _) = runtime()
        r.run("""
        export class Counter { constructor() { this.n = 0; } inc() { return ++this.n; } }
        const c = new Counter();
        console.log(c.inc(), c.inc(), typeof exports.Counter);
        """)
        XCTAssertEqual(out(), "1 2 function\n")
    }

    func testEsmExportDefault() {
        let (r, out, _) = runtime()
        r.run("""
        export default { tag: "v1" };
        console.log(JSON.stringify(exports.default), exports.__esModule);
        """)
        XCTAssertEqual(out(), "{\"tag\":\"v1\"} true\n")
    }

    func testEsmExportNamedRename() {
        let (r, out, _) = runtime()
        r.run("""
        const x = 10, y = 20;
        export { x as alpha, y as beta };
        console.log(exports.alpha, exports.beta);
        """)
        XCTAssertEqual(out(), "10 20\n")
    }

    func testEsmImportNamed() {
        let (r, out, _) = runtime()
        r.run("""
        import { join } from "node:path";
        console.log(join("a", "b", "c"));
        """)
        XCTAssertEqual(out(), "a/b/c\n")
    }

    func testEsmImportDefault() {
        let (r, out, _) = runtime()
        r.run("""
        import path from "node:path";
        console.log(path.join("x", "y"));
        """)
        XCTAssertEqual(out(), "x/y\n")
    }

    func testEsmImportNamespace() {
        let (r, out, _) = runtime()
        r.run("""
        import * as fs from "node:fs";
        console.log(typeof fs.readFileSync, typeof fs.statSync);
        """)
        XCTAssertEqual(out(), "function function\n")
    }

    func testEsmImportCombined() {
        let (r, out, _) = runtime()
        r.run("""
        import path, { join } from "node:path";
        console.log(typeof path.join, join("p", "q"));
        """)
        XCTAssertEqual(out(), "function p/q\n")
    }

    func testEsmDynamicImport() {
        let (r, out, _) = runtime()
        r.run("""
        import("node:path").then(p => console.log(p.join("d", "e")));
        """)
        XCTAssertEqual(out(), "d/e\n")
    }

    func testEsmMultiFileMjs() throws {
        let (r, out, _) = runtime()
        let dir = NSTemporaryDirectory() + "swiftjs-esm-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try """
        export const tag = (s) => `[${s}]`;
        export default { name: "u" };
        """.write(toFile: dir + "u.mjs", atomically: true, encoding: .utf8)

        try """
        import u, { tag } from "./u.mjs";
        console.log(tag(u.name));
        """.write(toFile: dir + "main.mjs", atomically: true, encoding: .utf8)

        try r.runFile(dir + "main.mjs")
        XCTAssertEqual(out(), "[u]\n")
    }

    func testEsmJsonImport() throws {
        let (r, out, _) = runtime()
        let dir = NSTemporaryDirectory() + "swiftjs-json-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try #"{"name":"alice","age":30}"#.write(toFile: dir + "data.json", atomically: true, encoding: .utf8)
        try """
        const d = require("./data.json");
        console.log(d.name, d.age);
        """.write(toFile: dir + "main.js", atomically: true, encoding: .utf8)

        try r.runFile(dir + "main.js")
        XCTAssertEqual(out(), "alice 30\n")
    }

    func testEsmNoFalsePositive() {
        // Strings that *look* like ESM but aren't shouldn't be rewritten.
        let (r, out, _) = runtime()
        r.run("""
        const s = "this string mentions import and export";
        console.log(s.includes("import"));
        """)
        XCTAssertEqual(out(), "true\n")
    }

    // MARK: - EnvProvider variants

    func testDictionaryEnvProviderRead() {
        var out = ""
        let r = JSRuntime(
            argv: ["swift-js"],
            envProvider: DictionaryEnvProvider(["TOKEN": "abc", "ROLE": "admin"]),
            stdout: { out += $0 },
            stderr: { _ in }
        )
        r.run("console.log(process.env.TOKEN, process.env.ROLE, process.env.MISSING ?? 'nil');")
        XCTAssertEqual(out, "abc admin nil\n")
    }

    func testDictionaryEnvProviderMutationsStayInRuntime() {
        var out = ""
        let provider = DictionaryEnvProvider(["X": "1"])
        let r = JSRuntime(
            argv: [], envProvider: provider,
            stdout: { out += $0 }, stderr: { _ in }
        )
        r.run("""
        process.env.X = 'rewritten';
        process.env.NEW = 'added';
        delete process.env.GONE;
        console.log(process.env.X, process.env.NEW);
        """)
        XCTAssertEqual(out, "rewritten added\n")
        // Mutations are visible on the Swift side too.
        XCTAssertEqual(provider.get("X"), "rewritten")
        XCTAssertEqual(provider.get("NEW"), "added")
    }

    func testEnvProxyEnumeration() {
        var out = ""
        let r = JSRuntime(
            argv: [],
            envProvider: DictionaryEnvProvider(["A": "1", "B": "2", "C": "3"]),
            stdout: { out += $0 }, stderr: { _ in }
        )
        r.run("""
        const keys = Object.keys(process.env).sort();
        console.log(keys.join(','));
        console.log('A' in process.env, 'Z' in process.env);
        """)
        XCTAssertEqual(out, "A,B,C\ntrue false\n")
    }

    // MARK: - ArgvProvider variants

    func testStaticArgvProviderDefault() {
        var out = ""
        let r = JSRuntime(
            argvProvider: StaticArgvProvider(["swift-js", "x.js", "alpha", "beta"]),
            envProvider: DictionaryEnvProvider(),
            stdout: { out += $0 }, stderr: { _ in }
        )
        r.run("console.log(process.argv.length, process.argv[2], process.argv[3]);")
        XCTAssertEqual(out, "4 alpha beta\n")
    }

    func testArgvIsRealArray() {
        var out = ""
        let r = JSRuntime(
            argvProvider: StaticArgvProvider(["swift-js", "s", "a", "b", "c"]),
            envProvider: DictionaryEnvProvider(),
            stdout: { out += $0 }, stderr: { _ in }
        )
        r.run("""
        console.log(Array.isArray(process.argv));
        console.log(process.argv.slice(2).join(','));
        const expanded = [...process.argv].join('|');
        console.log(expanded);
        """)
        XCTAssertEqual(out, "true\na,b,c\nswift-js|s|a|b|c\n")
    }

    func testShellArgvProviderSeesShellPositionals() async throws {
        // bash sets $1..$3, JS reads process.argv.slice(2).
        let shell = Shell()
        shell.registerStandardCommands()
        shell.positionalParameters = ["red", "green", "blue"]

        var out = ""
        let r = JSRuntime(
            argvProvider: ShellArgvProvider(shell, interpreter: "swift-js", scriptPath: "demo.js"),
            envProvider: DictionaryEnvProvider(),
            stdout: { out += $0 }, stderr: { _ in }
        )
        r.run("""
        console.log("argv:", JSON.stringify(process.argv));
        """)
        XCTAssertEqual(out,
            #"argv: ["swift-js","demo.js","red","green","blue"]"# + "\n")
    }

    func testRefreshArgvAfterShellMutation() {
        // Long-lived runtime: bash sets new positionals between runs,
        // JS sees the new values after refreshArgv().
        let shell = Shell()
        shell.registerStandardCommands()
        shell.positionalParameters = ["one"]

        var out = ""
        let r = JSRuntime(
            argvProvider: ShellArgvProvider(shell, interpreter: "i", scriptPath: "s"),
            envProvider: DictionaryEnvProvider(),
            stdout: { out += $0 }, stderr: { _ in }
        )

        r.run("console.log(process.argv.slice(2).join(','));")
        // → "one"
        shell.positionalParameters = ["two", "three"]
        r.refreshArgv()
        r.run("console.log(process.argv.slice(2).join(','));")
        // → "two,three"

        XCTAssertEqual(out, "one\ntwo,three\n")
    }

    func testShellEnvProviderRoundTrip() async throws {
        // The novel bit: a JS script and a bash script share an
        // env via a single Shell instance. Neither touches the
        // host process environment.
        let shell = Shell()
        shell.registerStandardCommands()
        shell.environment["FROM_BASH"] = "hi"
        shell.environment["SHARED"] = "v1"

        var out = ""
        let r = JSRuntime(
            argv: [], envProvider: ShellEnvProvider(shell),
            stdout: { out += $0 }, stderr: { _ in }
        )
        r.run("""
        console.log('js sees:', process.env.FROM_BASH, process.env.SHARED);
        process.env.SHARED = 'v2-from-js';
        process.env.FROM_JS = 'reply';
        """)
        XCTAssertEqual(out, "js sees: hi v1\n")

        // Mutations made by JS are visible to the shell.
        XCTAssertEqual(shell.environment["SHARED"], "v2-from-js")
        XCTAssertEqual(shell.environment["FROM_JS"], "reply")
        // And they did NOT escape to the host process.
        XCTAssertNil(ProcessInfo.processInfo.environment["FROM_JS"])
    }

    // MARK: - process.stdout / stderr / exitCode / on(exit)

    func testProcessStdoutWrite() {
        let (r, out, _) = runtime()
        r.run(#"process.stdout.write("hi"); process.stdout.write(" "); process.stdout.write("there");"#)
        XCTAssertEqual(out(), "hi there")
    }

    func testProcessExitCodeProperty() {
        let (r, _, _) = runtime()
        r.run("process.exitCode = 9; /* no exit() call */")
        XCTAssertEqual(r.exitCode, 9)
    }

    func testProcessOnExitCallback() {
        let (r, out, _) = runtime()
        r.run("""
        process.on('exit', (code) => process.stdout.write('bye-' + code));
        process.stdout.write('alive\\n');
        """)
        r.fireExitListeners()
        XCTAssertEqual(out(), "alive\nbye-0")
    }

    // MARK: - performance / structuredClone

    func testPerformanceNowMonotonic() {
        let (r, out, _) = runtime()
        r.run("""
        const a = performance.now();
        const b = performance.now();
        console.log(typeof a === 'number', b >= a);
        """)
        XCTAssertEqual(out(), "true true\n")
    }

    func testStructuredClone() {
        let (r, out, _) = runtime()
        r.run("""
        const a = { x: 1, ys: [{n:2}] };
        const b = structuredClone(a);
        b.ys[0].n = 99;
        console.log(a.ys[0].n, b.ys[0].n);
        """)
        XCTAssertEqual(out(), "2 99\n")
    }

    // MARK: - AbortController

    func testAbortController() {
        let (r, out, _) = runtime()
        r.run("""
        const ac = new AbortController();
        let fired = false;
        ac.signal.addEventListener('abort', () => { fired = true; });
        console.log(ac.signal.aborted, fired);
        ac.abort();
        console.log(ac.signal.aborted, fired, ac.signal.reason.name);
        """)
        XCTAssertEqual(out(), "false false\ntrue true AbortError\n")
    }

    // MARK: - extended console

    func testConsoleCountAndGroup() {
        let (r, out, _) = runtime()
        r.run("""
        console.count('a');
        console.count('a');
        console.group('outer');
        console.log('hi');
        console.groupEnd();
        """)
        XCTAssertEqual(out(), "a: 1\na: 2\nouter\n  hi\n")
    }

    func testConsoleTime() {
        let (r, out, _) = runtime()
        r.run("""
        console.time('t');
        for (let i = 0; i < 100; i++) {}
        console.timeEnd('t');
        """)
        XCTAssertTrue(out().hasPrefix("t: "))
        XCTAssertTrue(out().hasSuffix("ms\n"))
    }

    // MARK: - node:zlib

    func testZlibGzipRoundTrip() {
        let (r, out, _) = runtime()
        r.run("""
        const zlib = require('node:zlib');
        // Input large enough to compress under the gzip header overhead.
        const text = 'hello world '.repeat(50);
        const gz = zlib.gzipSync(text);
        const back = zlib.gunzipSync(gz).toString('utf-8');
        console.log(back === text, gz.length < text.length);
        """)
        XCTAssertEqual(out(), "true true\n")
    }

    func testZlibDeflateRoundTrip() {
        let (r, out, _) = runtime()
        r.run("""
        const zlib = require('zlib');
        const data = Buffer.from('the quick brown fox jumps over the lazy dog the quick brown fox');
        const z = zlib.deflateSync(data);
        const back = zlib.inflateSync(z).toString('utf-8');
        console.log(back, z.length < data.length);
        """)
        XCTAssertEqual(out(),
            "the quick brown fox jumps over the lazy dog the quick brown fox true\n")
    }

    func testZlibRawRoundTrip() {
        let (r, out, _) = runtime()
        r.run("""
        const zlib = require('zlib');
        const z = zlib.deflateRawSync('aaaaaaaaaaaaaaaa');
        const back = zlib.inflateRawSync(z).toString('utf-8');
        console.log(back === 'aaaaaaaaaaaaaaaa');
        """)
        XCTAssertEqual(out(), "true\n")
    }

    // MARK: - node:assert

    func testAssertModule() {
        let (r, out, _) = runtime()
        r.run("""
        const assert = require('node:assert');
        assert.equal(2 + 2, 4);
        assert.deepEqual([1,2], [1,2]);
        assert.strictEqual('x','x');
        assert.throws(() => { throw new Error('nope') }, /nope/);
        try { assert.strictEqual(1, '1'); } catch (e) { console.log(e.code); }
        """)
        XCTAssertEqual(out(), "ERR_ASSERTION\n")
    }

    // MARK: - node:events

    func testEventEmitter() {
        let (r, out, _) = runtime()
        r.run("""
        const { EventEmitter } = require('node:events');
        const ee = new EventEmitter();
        let count = 0;
        ee.on('tick', n => { count += n; });
        ee.emit('tick', 1);
        ee.emit('tick', 2);
        ee.emit('tick', 3);
        console.log(count, ee.listenerCount('tick'));
        """)
        XCTAssertEqual(out(), "6 1\n")
    }

    func testEventEmitterOnce() {
        let (r, out, _) = runtime()
        r.run("""
        const { EventEmitter } = require('events');
        const ee = new EventEmitter();
        let n = 0;
        ee.once('go', () => n++);
        ee.emit('go'); ee.emit('go'); ee.emit('go');
        console.log(n);
        """)
        XCTAssertEqual(out(), "1\n")
    }

    // MARK: - node:querystring

    func testQuerystring() {
        let (r, out, _) = runtime()
        r.run("""
        const qs = require('node:querystring');
        console.log(JSON.stringify(qs.parse('a=1&b=2&a=3')));
        console.log(qs.stringify({x: 'hello world', y: [1,2]}));
        """)
        XCTAssertEqual(out(),
            "{\"a\":[\"1\",\"3\"],\"b\":\"2\"}\nx=hello+world&y=1&y=2\n")
    }

    // MARK: - WebAssembly (free from JSC)

    func testWebAssemblySync() {
        let (r, out, _) = runtime()
        r.run("""
        const wasm = new Uint8Array([
          0,97,115,109, 1,0,0,0,
          1,7,1,96,2,127,127,1,127,
          3,2,1,0,
          7,7,1,3,97,100,100,0,0,
          10,9,1,7,0,32,0,32,1,106,11,
        ]);
        const m = new WebAssembly.Module(wasm.buffer);
        const inst = new WebAssembly.Instance(m);
        console.log(inst.exports.add(40, 2));
        """)
        XCTAssertEqual(out(), "42\n")
    }

    // MARK: - util

    func testUtilFormat() {
        let (r, out, _) = runtime()
        r.run("""
        const util = require('node:util');
        console.log(util.format('%s is %d', 'x', 7));
        console.log(util.format('%j', {a:1}));
        """)
        XCTAssertEqual(out(), "x is 7\n{\"a\":1}\n")
    }
}

#endif
