// CI proof that JavaScriptCore's C API loads and evaluates JS on
// every supported platform — Apple via the system framework,
// Linux/Android via the static archive shipped in Bun's
// `bun-webkit-<triple>.tar.gz` tarball staged by
// `scripts/fetch-bun-webkit.sh`. Windows is gated off at the
// dependency level for now (Bun's `.lib`s are MSVC `/MT` static
// CRT, Swift's runtime is `/MD` dynamic CRT — `lld-link` rejects
// the mix); tracked as a follow-up in Docs/SwiftJS.md.
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

#if canImport(CJavaScriptCore)
import CJavaScriptCore

func stage(_ message: String) {
    print("swift-jsc-smoke: [stage] \(message)")
    fflush(stdout)
}

func evaluate(_ source: String) -> Double {
    // Use the explicit context-group lifecycle (`JSContextGroupCreate`
    // + `JSGlobalContextCreateInGroup` + release context, then group)
    // rather than the bare `JSGlobalContextCreate(nil)` /
    // `JSGlobalContextRelease` pair. Same VM, but the teardown runs
    // from inside `JSContextGroupRelease`'s `JSLockHolder` scope,
    // which is the only release path that exits cleanly on Bun's
    // `bun-webkit` static archive (oven-sh/bun#30434). On Apple's
    // framework JSC the two paths are equivalent.
    stage("JSContextGroupCreate")
    guard let group = JSContextGroupCreate() else {
        print("swift-jsc-smoke: JSContextGroupCreate returned nil")
        fflush(stdout)
        exit(1)
    }
    stage("JSGlobalContextCreateInGroup")
    guard let ctx = JSGlobalContextCreateInGroup(group, nil) else {
        print("swift-jsc-smoke: JSGlobalContextCreateInGroup returned nil")
        fflush(stdout)
        exit(1)
    }

    stage("JSStringCreateWithUTF8CString")
    guard let scriptRef = source.withCString(JSStringCreateWithUTF8CString)
    else {
        print("swift-jsc-smoke: JSStringCreateWithUTF8CString failed")
        fflush(stdout)
        exit(1)
    }

    stage("JSEvaluateScript")
    var exception: JSValueRef?
    guard let result = JSEvaluateScript(ctx, scriptRef, nil, nil, 0,
                                        &exception)
    else {
        JSStringRelease(scriptRef)
        JSGlobalContextRelease(ctx)
        JSContextGroupRelease(group)
        print("swift-jsc-smoke: JSEvaluateScript returned nil")
        fflush(stdout)
        exit(1)
    }
    if exception != nil {
        JSStringRelease(scriptRef)
        JSGlobalContextRelease(ctx)
        JSContextGroupRelease(group)
        print("swift-jsc-smoke: script raised an exception")
        fflush(stdout)
        exit(1)
    }

    stage("JSValueToNumber")
    let n = JSValueToNumber(ctx, result, nil)
    stage("JSValueToNumber returned: \(n)")

    // Tear everything down deliberately — context first, then group.
    // Used to be skipped because `JSGlobalContextRelease` hangs on
    // bun-webkit; the group-release path doesn't.
    stage("JSStringRelease")
    JSStringRelease(scriptRef)
    stage("JSGlobalContextRelease (drops ctx ref)")
    JSGlobalContextRelease(ctx)
    stage("JSContextGroupRelease (drops group ref → ~VM)")
    JSContextGroupRelease(group)
    stage("teardown complete")
    return n
}

let result = evaluate("1 + 2")
stage("evaluate returned: \(result)")
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
fflush(stdout)
exit(0)

#else  // !canImport(CJavaScriptCore)

// Windows currently — see file header for why.
print("swift-jsc-smoke: skipped on this platform " +
      "(see Docs/SwiftJS.md § Cross-platform)")
exit(0)

#endif
