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
import Foundation
import CJavaScriptCore

func evaluate(_ source: String) -> Double {
    guard let ctx = JSGlobalContextCreate(nil) else {
        fputs("swift-jsc-smoke: JSGlobalContextCreate returned nil\n",
              stderr)
        exit(1)
    }
    defer { JSGlobalContextRelease(ctx) }

    guard let scriptRef = source.withCString(JSStringCreateWithUTF8CString)
    else {
        fputs("swift-jsc-smoke: JSStringCreateWithUTF8CString failed\n",
              stderr)
        exit(1)
    }
    defer { JSStringRelease(scriptRef) }

    var exception: JSValueRef?
    guard let result = JSEvaluateScript(ctx, scriptRef, nil, nil, 0,
                                        &exception)
    else {
        fputs("swift-jsc-smoke: JSEvaluateScript returned nil\n",
              stderr)
        exit(1)
    }
    if exception != nil {
        fputs("swift-jsc-smoke: script raised an exception\n", stderr)
        exit(1)
    }
    return JSValueToNumber(ctx, result, nil)
}

let result = evaluate("1 + 2")
guard result == 3.0 else {
    fputs("swift-jsc-smoke: expected 3.0, got \(result)\n", stderr)
    exit(1)
}

#if canImport(Darwin)
let backend = "JavaScriptCore.framework (Apple)"
#else
let backend = "bun-webkit static archive"
#endif
print("swift-jsc-smoke: 1 + 2 = \(Int(result))  [\(backend)]")
