import Foundation
import JavaScriptCore
import CZlib

#if canImport(JavaScriptCore)

/// `node:zlib` — gzip/gunzip/deflate/inflate.
///
/// Sync-only for now (matches the rest of our fs/crypto surface).
/// Backed by the host zlib (`libz.dylib` on Apple, `libz.so` on Linux)
/// via the parent package's `CZlib` systemLibrary shim.
extension JSRuntime {

    func makeZlibModule() -> JSValue {
        let zlib = JSValue(newObjectIn: context)!

        // gzipSync(buf|string) → Buffer (gzip format, with header)
        let gzipSync: @convention(block) (JSValue) -> Any? = { [weak self] input in
            guard let self else { return nil }
            let bytes = JSRuntime.bytesForZlibInput(input)
            guard let out = JSRuntime.zlibCompress(bytes, format: .gzip) else {
                return self.throwJS("zlib gzip failed")
            }
            return self.bufferFromBytes(out)
        }
        zlib.setObject(block(gzipSync as AnyObject),
                       forKeyedSubscript: "gzipSync" as NSString)

        // gunzipSync(buf) → Buffer
        let gunzipSync: @convention(block) (JSValue) -> Any? = { [weak self] input in
            guard let self else { return nil }
            let bytes = JSRuntime.bytesForZlibInput(input)
            guard let out = JSRuntime.zlibDecompress(bytes, format: .gzip) else {
                return self.throwJS("zlib gunzip failed")
            }
            return self.bufferFromBytes(out)
        }
        zlib.setObject(block(gunzipSync as AnyObject),
                       forKeyedSubscript: "gunzipSync" as NSString)

        // deflateSync(buf|string) → Buffer (zlib format)
        let deflateSync: @convention(block) (JSValue) -> Any? = { [weak self] input in
            guard let self else { return nil }
            let bytes = JSRuntime.bytesForZlibInput(input)
            guard let out = JSRuntime.zlibCompress(bytes, format: .zlib) else {
                return self.throwJS("zlib deflate failed")
            }
            return self.bufferFromBytes(out)
        }
        zlib.setObject(block(deflateSync as AnyObject),
                       forKeyedSubscript: "deflateSync" as NSString)

        // inflateSync(buf) → Buffer
        let inflateSync: @convention(block) (JSValue) -> Any? = { [weak self] input in
            guard let self else { return nil }
            let bytes = JSRuntime.bytesForZlibInput(input)
            guard let out = JSRuntime.zlibDecompress(bytes, format: .zlib) else {
                return self.throwJS("zlib inflate failed")
            }
            return self.bufferFromBytes(out)
        }
        zlib.setObject(block(inflateSync as AnyObject),
                       forKeyedSubscript: "inflateSync" as NSString)

        // deflateRawSync / inflateRawSync — raw deflate (no header).
        let deflateRawSync: @convention(block) (JSValue) -> Any? = { [weak self] input in
            guard let self else { return nil }
            let bytes = JSRuntime.bytesForZlibInput(input)
            guard let out = JSRuntime.zlibCompress(bytes, format: .raw) else {
                return self.throwJS("zlib deflateRaw failed")
            }
            return self.bufferFromBytes(out)
        }
        zlib.setObject(block(deflateRawSync as AnyObject),
                       forKeyedSubscript: "deflateRawSync" as NSString)

        let inflateRawSync: @convention(block) (JSValue) -> Any? = { [weak self] input in
            guard let self else { return nil }
            let bytes = JSRuntime.bytesForZlibInput(input)
            guard let out = JSRuntime.zlibDecompress(bytes, format: .raw) else {
                return self.throwJS("zlib inflateRaw failed")
            }
            return self.bufferFromBytes(out)
        }
        zlib.setObject(block(inflateRawSync as AnyObject),
                       forKeyedSubscript: "inflateRawSync" as NSString)

        return zlib
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

extension JSRuntime {

    fileprivate static func zlibCompress(_ src: [UInt8], format: ZlibFormat) -> [UInt8]? {
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
        guard initRC == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        var output: [UInt8] = []
        return src.withUnsafeBufferPointer { srcBuf -> [UInt8]? in
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
                if rc == Z_STREAM_END { return output }
                if rc != Z_OK && rc != Z_BUF_ERROR { return nil }
            }
        }
    }

    fileprivate static func zlibDecompress(_ src: [UInt8], format: ZlibFormat) -> [UInt8]? {
        var stream = z_stream()
        let initRC = inflateInit2_(
            &stream,
            format.windowBits,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initRC == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output: [UInt8] = []
        return src.withUnsafeBufferPointer { srcBuf -> [UInt8]? in
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
                if rc == Z_STREAM_END { return output }
                if rc != Z_OK { return nil }
            }
        }
    }
}
#endif
