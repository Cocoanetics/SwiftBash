import Foundation
import CZlib

#if canImport(JavaScriptCore)

import JavaScriptCore

/// `node:zlib` — gzip/gunzip/deflate/inflate.
///
/// Sync-only for now (matches the rest of our fs/crypto surface).
/// Backed by the host zlib (`libz.dylib` on Apple, `libz.so` on Linux)
/// via the parent package's `CZlib` systemLibrary shim.
extension JSRuntime {

    func makeZlibModule() -> JSValue {
        let zlib = JSValue(newObjectIn: context)!

        // Each *Sync entry funnels through `bridge`, which decorates a
        // failed compress/decompress with the underlying zlib message
        // (`stream.msg`) and a Node-shaped `code` (`Z_DATA_ERROR`,
        // `Z_BUF_ERROR`, …). Without that, errors looked like the
        // generic "zlib gunzip failed", and a truncated gzip stream
        // and an OOM would be indistinguishable to the caller.
        let bridge: (String, @escaping (JSValue) -> JSResult) -> @convention(block) (JSValue) -> Any? = { [weak self] op, body in
            { input in
                guard let self else { return nil }
                switch body(input) {
                case .ok(let bytes):
                    return self.bufferFromBytes(bytes)
                case .err(let rc, let message):
                    let code = JSRuntime.zlibCodeName(rc)
                    let detail = message ?? JSRuntime.zlibDescription(rc)
                    return self.throwJSError(
                        "zlib: \(op) failed: \(detail)",
                        code: code,
                        extras: ["errno": Int(rc)]
                    )
                }
            }
        }

        let gzipSync = bridge("gzip") { input in
            JSRuntime.zlibCompress(JSRuntime.bytesForZlibInput(input), format: .gzip)
        }
        zlib.setObject(block(gzipSync as AnyObject),
                       forKeyedSubscript: "gzipSync" as NSString)

        let gunzipSync = bridge("gunzip") { input in
            JSRuntime.zlibDecompress(JSRuntime.bytesForZlibInput(input), format: .gzip)
        }
        zlib.setObject(block(gunzipSync as AnyObject),
                       forKeyedSubscript: "gunzipSync" as NSString)

        let deflateSync = bridge("deflate") { input in
            JSRuntime.zlibCompress(JSRuntime.bytesForZlibInput(input), format: .zlib)
        }
        zlib.setObject(block(deflateSync as AnyObject),
                       forKeyedSubscript: "deflateSync" as NSString)

        let inflateSync = bridge("inflate") { input in
            JSRuntime.zlibDecompress(JSRuntime.bytesForZlibInput(input), format: .zlib)
        }
        zlib.setObject(block(inflateSync as AnyObject),
                       forKeyedSubscript: "inflateSync" as NSString)

        let deflateRawSync = bridge("deflateRaw") { input in
            JSRuntime.zlibCompress(JSRuntime.bytesForZlibInput(input), format: .raw)
        }
        zlib.setObject(block(deflateRawSync as AnyObject),
                       forKeyedSubscript: "deflateRawSync" as NSString)

        let inflateRawSync = bridge("inflateRaw") { input in
            JSRuntime.zlibDecompress(JSRuntime.bytesForZlibInput(input), format: .raw)
        }
        zlib.setObject(block(inflateRawSync as AnyObject),
                       forKeyedSubscript: "inflateRawSync" as NSString)

        return zlib
    }

    /// Map a zlib return code (Z_DATA_ERROR, Z_BUF_ERROR, …) to its
    /// Node-style symbolic name. Used as the `.code` on the JS Error
    /// thrown from a failed compress/decompress.
    fileprivate static func zlibCodeName(_ rc: Int32) -> String {
        switch rc {
        case Z_STREAM_ERROR: return "Z_STREAM_ERROR"
        case Z_DATA_ERROR:   return "Z_DATA_ERROR"
        case Z_MEM_ERROR:    return "Z_MEM_ERROR"
        case Z_BUF_ERROR:    return "Z_BUF_ERROR"
        case Z_VERSION_ERROR: return "Z_VERSION_ERROR"
        default:             return "Z_ERRNO"
        }
    }

    fileprivate static func zlibDescription(_ rc: Int32) -> String {
        switch rc {
        case Z_STREAM_ERROR:  return "invalid stream state"
        case Z_DATA_ERROR:    return "incorrect data check / corrupted input"
        case Z_MEM_ERROR:     return "not enough memory"
        case Z_BUF_ERROR:     return "no progress is possible"
        case Z_VERSION_ERROR: return "zlib version mismatch"
        default:              return "zlib failed (rc=\(rc))"
        }
    }

    private func bufferFromBytes(_ bytes: [UInt8]) -> JSValue {
        let bufferCtor = context.objectForKeyedSubscript("Buffer")!
        return bufferCtor.invokeMethod("from", withArguments: [bytes])!
    }

    /// Pull bytes out of a string|Buffer|Uint8Array argument.
    fileprivate static func bytesForZlibInput(_ value: JSValue) -> [UInt8] {
        if value.isString {
            return Array((value.toString() ?? "").utf8)
        }
        if let arr = value.toArray() as? [NSNumber] {
            return arr.map { $0.uint8Value }
        }
        return []
    }
}

// MARK: - zlib glue
//
// Three "windowBits" conventions, all in zlib's `deflateInit2`:
//   - 15      → zlib format (RFC 1950, with adler32 trailer)
//   - 15 + 16 → gzip format (RFC 1952, with header + crc32)
//   - -15     → raw deflate (RFC 1951, no wrapper)

private enum ZlibFormat {
    case zlib, gzip, raw
    var windowBits: Int32 {
        switch self {
        case .zlib: return 15
        case .gzip: return 15 + 16
        case .raw:  return -15
        }
    }
}

/// Result of a single zlib compress/decompress attempt. Carries the
/// rc and `stream.msg` along with the bytes so the JS side can throw
/// a Node-shaped Error with a useful diagnostic.
enum JSResult {
    case ok([UInt8])
    case err(rc: Int32, message: String?)
}

extension JSResult {
    static func err(_ rc: Int32, _ message: String?) -> JSResult {
        .err(rc: rc, message: message)
    }
}

extension JSRuntime {

    fileprivate static func zlibCompress(_ src: [UInt8], format: ZlibFormat) -> JSResult {
        var stream = z_stream()
        let level = Int32(Z_DEFAULT_COMPRESSION)
        let initRC = deflateInit2_(
            &stream, level,
            Int32(Z_DEFLATED),
            format.windowBits,
            8 /* memLevel */,
            Int32(Z_DEFAULT_STRATEGY),
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initRC == Z_OK else { return .err(initRC, zlibStreamMessage(&stream)) }
        defer { deflateEnd(&stream) }

        var output: [UInt8] = []
        return src.withUnsafeBufferPointer { srcBuf -> JSResult in
            stream.next_in = UnsafeMutablePointer(mutating: srcBuf.baseAddress)
            stream.avail_in = UInt32(srcBuf.count)

            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let rc = chunk.withUnsafeMutableBufferPointer { dst -> Int32 in
                    stream.next_out = dst.baseAddress
                    stream.avail_out = UInt32(dst.count)
                    return deflate(&stream, Z_FINISH)
                }
                let written = chunk.count - Int(stream.avail_out)
                output.append(contentsOf: chunk[..<written])
                if rc == Z_STREAM_END { return .ok(output) }
                if rc != Z_OK && rc != Z_BUF_ERROR {
                    return .err(rc, zlibStreamMessage(&stream))
                }
            }
        }
    }

    fileprivate static func zlibDecompress(_ src: [UInt8], format: ZlibFormat) -> JSResult {
        var stream = z_stream()
        let initRC = inflateInit2_(
            &stream,
            format.windowBits,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initRC == Z_OK else { return .err(initRC, zlibStreamMessage(&stream)) }
        defer { inflateEnd(&stream) }

        var output: [UInt8] = []
        return src.withUnsafeBufferPointer { srcBuf -> JSResult in
            stream.next_in = UnsafeMutablePointer(mutating: srcBuf.baseAddress)
            stream.avail_in = UInt32(srcBuf.count)

            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let rc = chunk.withUnsafeMutableBufferPointer { dst -> Int32 in
                    stream.next_out = dst.baseAddress
                    stream.avail_out = UInt32(dst.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let written = chunk.count - Int(stream.avail_out)
                output.append(contentsOf: chunk[..<written])
                if rc == Z_STREAM_END { return .ok(output) }
                if rc != Z_OK {
                    return .err(rc, zlibStreamMessage(&stream))
                }
            }
        }
    }

    /// Pull the human-readable diagnostic out of `stream.msg`, which
    /// zlib points at a static C string when something goes wrong
    /// (e.g. "incorrect header check"). Nil when zlib didn't set one.
    private static func zlibStreamMessage(_ stream: UnsafePointer<z_stream>) -> String? {
        guard let cstr = stream.pointee.msg else { return nil }
        return String(cString: cstr)
    }
}
#endif
