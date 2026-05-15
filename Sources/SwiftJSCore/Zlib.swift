#if !os(Windows)

import Foundation

// GzipKit is gated off on Android in Package.swift (the SwiftPorts
// dep graph isn't viable on Bionic). Guard the whole file's
// implementation so SwiftJSCore still compiles there — Android
// scripts that `require('zlib')` get an empty module instead of
// the gzip/deflate suite, which is acceptable since the embedder
// already opted out of GzipKit.
#if canImport(GzipKit)
import GzipKit

/// `node:zlib` — gzip/gunzip/deflate/inflate.
///
/// Sync-only for now (matches the rest of our fs/crypto surface).
/// Backed by [`GzipKit.Zlib`](https://github.com/Cocoanetics/SwiftPorts)
/// — the synchronous variants (`compressSync` / `decompressSync`)
/// are the right shape for the JS-runtime hook (JavaScriptCore's
/// main-queue model can't `await` from a synchronous JS→Swift bridge).
///
/// Three wrap modes match Node's API exactly:
///   - `gzipSync` / `gunzipSync` — `Zlib.Wrap.gzip` (windowBits 31).
///   - `deflateSync` / `inflateSync` — `Zlib.Wrap.zlib` (windowBits 15).
///   - `deflateRawSync` / `inflateRawSync` — `Zlib.Wrap.raw` (windowBits -15).
///
/// Failures raise a JS Error with `code` set to the Node-style symbolic
/// rc (`Z_DATA_ERROR`, `Z_BUF_ERROR`, …) — `ZlibError.code` already
/// produces that string from the underlying zlib rc.
extension JSRuntime {

    func makeZlibModule() -> JSValue {
        let zlib = JSValue(newObjectIn: context)!

        // Each *Sync entry funnels through `bridge`, which decorates a
        // failed compress/decompress with the underlying zlib message
        // and a Node-shaped `code`.
        let bridge: (String, @escaping (Data) throws -> Data) -> JSValue = { [weak self] opName, body in
            return self!.block { args in
                guard let self, let input = args.first else { return nil }
                let bytes = JSRuntime.dataForZlibInput(input)
                do {
                    let out = try body(bytes)
                    return self.bufferFromBytes([UInt8](out))
                } catch let zlibErr as ZlibError {
                    return self.throwJSError(
                        "zlib: \(opName) failed: \(zlibErr.message ?? "rc=\(zlibErr.rc)")",
                        code: zlibErr.code,
                        extras: ["errno": Int(zlibErr.rc)]
                    )
                } catch {
                    return self.throwJSError(
                        "zlib: \(opName) failed: \(error)",
                        code: "Z_ERRNO",
                        extras: [:]
                    )
                }
            }
        }

        zlib.setObject(bridge("gzip") { try Zlib.compressSync($0, wrap: .gzip) },
                       forKeyedSubscript: "gzipSync")
        zlib.setObject(bridge("gunzip") { try Zlib.decompressSync($0, wrap: .gzip) },
                       forKeyedSubscript: "gunzipSync")
        zlib.setObject(bridge("deflate") { try Zlib.compressSync($0, wrap: .zlib) },
                       forKeyedSubscript: "deflateSync")
        zlib.setObject(bridge("inflate") { try Zlib.decompressSync($0, wrap: .zlib) },
                       forKeyedSubscript: "inflateSync")
        zlib.setObject(bridge("deflateRaw") { try Zlib.compressSync($0, wrap: .raw) },
                       forKeyedSubscript: "deflateRawSync")
        zlib.setObject(bridge("inflateRaw") { try Zlib.decompressSync($0, wrap: .raw) },
                       forKeyedSubscript: "inflateRawSync")

        return zlib
    }

    private func bufferFromBytes(_ bytes: [UInt8]) -> JSValue {
        let bufferCtor = context.objectForKeyedSubscript("Buffer")!
        return bufferCtor.invokeMethod("from", withArguments: [bytes])!
    }

    /// Pull bytes out of a string|Buffer|Uint8Array argument.
    fileprivate static func dataForZlibInput(_ value: JSValue) -> Data {
        if value.isString {
            return Data((value.toString() ?? "").utf8)
        }
        if let arr = value.toArray() as? [NSNumber] {
            return Data(arr.map { $0.uint8Value })
        }
        return Data()
    }
}

#else  // !canImport(GzipKit) — Android

extension JSRuntime {
    /// Stub module on platforms without GzipKit. Returns an empty
    /// JS object so `require('zlib')` doesn't fail outright, but
    /// none of the gzip/deflate methods are available.
    func makeZlibModule() -> JSValue {
        return JSValue(newObjectIn: context)!
    }
}

#endif
#endif  // !os(Windows)
