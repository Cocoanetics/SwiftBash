// CI proof that JavaScriptCore's C API loads and evaluates JS on
// every supported platform — Apple via the system framework,
// Linux/Windows/Android via the static archive shipped in Bun's
// `bun-webkit-<triple>.tar.gz` tarball staged by
// `scripts/fetch-bun-webkit.sh`.
//
// The test is compile-and-run, not unit-test, because it has to
// link the full WebKit JSC artifact — a unit test fixture would
// pull the same dependency graph anyway, and a top-level executable
// keeps the smoke check observable in CI logs ("1 + 2 = 3" lands
// at the end of the build job).
//
// Stage markers are printed and flushed before each JSC C-API
// call so a runtime crash (`Aborted (core dumped)` with no other
// output) localises to the last marker that made it to the log.
import Foundation
import CJavaScriptCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Bionic)
import Bionic
#elseif canImport(ucrt)
import ucrt
#endif

func stage(_ message: String) {
    print("swift-jsc-smoke: [stage] \(message)")
    fflush(stdout)
}

func evaluate(_ source: String) -> Double {
    stage("JSGlobalContextCreate")
    guard let ctx = JSGlobalContextCreate(nil) else {
        print("swift-jsc-smoke: JSGlobalContextCreate returned nil")
        fflush(stdout)
        exit(1)
    }
    defer { JSGlobalContextRelease(ctx) }

    stage("JSStringCreateWithUTF8CString")
    guard let scriptRef = source.withCString(JSStringCreateWithUTF8CString)
    else {
        print("swift-jsc-smoke: JSStringCreateWithUTF8CString failed")
        fflush(stdout)
        exit(1)
    }
    defer { JSStringRelease(scriptRef) }

    stage("JSEvaluateScript")
    var exception: JSValueRef?
    guard let result = JSEvaluateScript(ctx, scriptRef, nil, nil, 0,
                                        &exception)
    else {
        print("swift-jsc-smoke: JSEvaluateScript returned nil")
        fflush(stdout)
        exit(1)
    }
    if exception != nil {
        print("swift-jsc-smoke: script raised an exception")
        fflush(stdout)
        exit(1)
    }

    stage("JSValueToNumber")
    return JSValueToNumber(ctx, result, nil)
}

let result = evaluate("1 + 2")
guard result == 3.0 else {
    print("swift-jsc-smoke: expected 3.0, got \(result)")
    fflush(stdout)
    exit(1)
}

#if canImport(Darwin)
let backend = "JavaScriptCore.framework (Apple)"
#else
let backend = "bun-webkit static archive"
#endif
print("swift-jsc-smoke: 1 + 2 = \(Int(result))  [\(backend)]")
