import XCTest
@testable import SwiftJSCore

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

    func testExecSyncEchoStringRoundTrip() {
        let (r, out, _) = runtime()
        r.run("""
        const cp = require('child_process');
        const text = cp.execSync('echo "swift-js"');
        console.log(text.trim());
        """)
        XCTAssertEqual(out(), "swift-js\n")
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
