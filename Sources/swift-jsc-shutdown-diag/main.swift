// CI-driven research probe for the bun-webkit JSC standalone-mode
// teardown stall (oven-sh/bun#30434). Each invocation runs ONE
// variant of the JSGlobalContext lifecycle, prints structured
// timing, and either completes cleanly or aborts. Hard timeout
// (10 s wall) forces a backtrace dump if the call hangs, so we
// don't burn CI minutes waiting for the natural ~62 s SIGABRT.
//
// Variants (selected by argv[1]):
//
//   plain       — create + release, no JS executed.
//   evaluated   — create + evaluate("1+2") + release.
//   gc-then-release — create + evaluate("1+2") + JSGarbageCollect + release.
//   group-release   — create + release-group, no per-context release.
//   no-release  — create only; never release. (Control — should always exit cleanly.)
//
// Each variant prints `[stage] ...` markers with monotonic timestamps
// so the CI log shows where the hang sits. The watchdog thread
// raises SIGABRT at 10 s elapsed if the main thread is still inside
// the release call — a debug Swift build then dumps a Swift
// backtrace, which is more useful than the bare 62-s wait.
import Foundation
import CJavaScriptCore

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

// ---- Timing helpers --------------------------------------------------------

let processStart = monotonicNs()

func monotonicNs() -> UInt64 {
    #if canImport(Darwin)
    return clock_gettime_nsec_np(CLOCK_MONOTONIC)
    #else
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    #endif
}

func elapsedMs() -> Double {
    Double(monotonicNs() - processStart) / 1_000_000.0
}

func stage(_ label: String) {
    let ms = elapsedMs()
    print(String(format: "[%8.2f ms] %@", ms, label))
    fflush(stdout)
}

// ---- Watchdog --------------------------------------------------------------
//
// If a variant hangs, fire SIGABRT after 10 s so CI doesn't sit there
// for the full natural 62 s. The signal flushes whatever output we've
// captured and dumps a backtrace.

func startWatchdog(seconds: Int) {
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
        stage("WATCHDOG: \(seconds) s elapsed without exit — raising SIGABRT")
        // Print a hint about what to look for in the trace.
        stage("WATCHDOG: thread is likely stuck inside JSGlobalContextRelease")
        raise(SIGABRT)
    }
}

// ---- Variants --------------------------------------------------------------

func variantPlain() {
    stage("variant=plain — JSGlobalContextCreate")
    guard let ctx = JSGlobalContextCreate(nil) else {
        stage("CREATE returned nil"); exit(2)
    }
    stage("created ctx=\(String(format: "%p", Int(bitPattern: UnsafeRawPointer(ctx))))")

    stage("calling JSGlobalContextRelease")
    JSGlobalContextRelease(ctx)
    stage("returned from JSGlobalContextRelease — clean")
}

func variantEvaluated() {
    stage("variant=evaluated — JSGlobalContextCreate")
    guard let ctx = JSGlobalContextCreate(nil) else { exit(2) }

    stage("evaluating 1 + 2")
    let scriptRef = JSStringCreateWithUTF8CString("1 + 2")
    var exception: JSValueRef?
    _ = JSEvaluateScript(ctx, scriptRef, nil, nil, 0, &exception)
    JSStringRelease(scriptRef)

    stage("calling JSGlobalContextRelease")
    JSGlobalContextRelease(ctx)
    stage("returned from JSGlobalContextRelease — clean")
}

func variantGCThenRelease() {
    stage("variant=gc-then-release — JSGlobalContextCreate")
    guard let ctx = JSGlobalContextCreate(nil) else { exit(2) }

    stage("evaluating 1 + 2")
    let scriptRef = JSStringCreateWithUTF8CString("1 + 2")
    var exception: JSValueRef?
    _ = JSEvaluateScript(ctx, scriptRef, nil, nil, 0, &exception)
    JSStringRelease(scriptRef)

    stage("calling JSGarbageCollect")
    JSGarbageCollect(ctx)

    stage("calling JSGlobalContextRelease")
    JSGlobalContextRelease(ctx)
    stage("returned from JSGlobalContextRelease — clean")
}

func variantGroupRelease() {
    stage("variant=group-release — JSContextGroupCreate")
    guard let group = JSContextGroupCreate() else { exit(2) }

    stage("JSGlobalContextCreateInGroup")
    guard let ctx = JSGlobalContextCreateInGroup(group, nil) else { exit(2) }

    stage("evaluating 1 + 2")
    let scriptRef = JSStringCreateWithUTF8CString("1 + 2")
    var exception: JSValueRef?
    _ = JSEvaluateScript(ctx, scriptRef, nil, nil, 0, &exception)
    JSStringRelease(scriptRef)

    stage("calling JSGlobalContextRelease (drops ctx ref)")
    JSGlobalContextRelease(ctx)
    stage("ctx released; calling JSContextGroupRelease (drops group ref)")
    JSContextGroupRelease(group)
    stage("returned from both releases — clean")
}

func variantNoRelease() {
    stage("variant=no-release — JSGlobalContextCreate")
    guard let ctx = JSGlobalContextCreate(nil) else { exit(2) }

    stage("evaluating 1 + 2 (skipping release deliberately)")
    let scriptRef = JSStringCreateWithUTF8CString("1 + 2")
    var exception: JSValueRef?
    _ = JSEvaluateScript(ctx, scriptRef, nil, nil, 0, &exception)
    JSStringRelease(scriptRef)

    stage("intentionally skipping JSGlobalContextRelease — exit 0")
    // Suppress "unused" warning by parking the pointer somewhere
    // the compiler can't elide.
    UnsafeMutableRawPointer(ctx).map { _ = $0 }
}

// ---- Entry point -----------------------------------------------------------

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: swift-jsc-shutdown-diag <plain|evaluated|gc-then-release|group-release|no-release>\n",
          stderr)
    exit(64)
}

#if canImport(Darwin)
let backend = "JavaScriptCore.framework (Apple)"
#else
let backend = "bun-webkit static archive"
#endif
stage("backend=\(backend) variant=\(args[1])")

// 10-s watchdog — long enough to confirm a clean release (which
// completes in milliseconds on Apple) but short enough to not burn
// CI minutes when the call hangs.
startWatchdog(seconds: 10)

switch args[1] {
case "plain":            variantPlain()
case "evaluated":        variantEvaluated()
case "gc-then-release":  variantGCThenRelease()
case "group-release":    variantGroupRelease()
case "no-release":       variantNoRelease()
default:
    fputs("unknown variant: \(args[1])\n", stderr)
    exit(64)
}

stage("variant exited cleanly")
exit(0)
