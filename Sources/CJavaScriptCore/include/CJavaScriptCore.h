// Umbrella header for the CJavaScriptCore module. Re-exports
// JavaScriptCore's stable C API (`JSContextRef`, `JSValueRef`,
// `JSStringRef`, `JSObjectRef`) so Swift can `import CJavaScriptCore`
// and call into JSC without depending on the Apple-only Objective-C
// wrapper layer (`JSContext` / `JSValue`).
//
// On Apple platforms the include resolves through the
// `JavaScriptCore.framework` umbrella; on Linux / Windows / Android
// it resolves to the headers shipped in Bun's prebuilt JSC tarball
// (oven-sh/WebKit autobuild), staged under `Vendor/bun-webkit/current/`
// by `scripts/fetch-bun-webkit.sh` and put on the include path in
// Package.swift. See Docs/SwiftJS.md § Cross-platform.
#ifndef CJavaScriptCore_h
#define CJavaScriptCore_h

#include <JavaScriptCore/JavaScript.h>

#endif /* CJavaScriptCore_h */
