import ArgumentParser
import BashInterpreter
import CZlib
import Foundation

// MARK: - gzip

/// Tiny gzip codec: header / trailer in pure Swift, DEFLATE body via
/// the host's zlib (`deflate` / `inflate` from `<zlib.h>`, exposed
/// through the local `CZlib` systemLibrary target). One-shot,
/// in-memory. Big files (>4 GiB) aren't supported because gzip's
/// `ISIZE` field is 32-bit, which we use as the decode buffer hint.
enum Gzip {

    enum Error: Swift.Error, CustomStringConvertible {
        case notGzip
        case unsupportedMethod
        case truncated
        case inflateFailed
        case deflateFailed

        var description: String {
            switch self {
            case .notGzip:            return "not in gzip format"
            case .unsupportedMethod:  return "unsupported compression method"
            case .truncated:          return "unexpected end of file"
            case .inflateFailed:      return "decompression failed"
            case .deflateFailed:      return "compression failed"
            }
        }
    }

    static func encode(_ src: Data) -> Data {
        var out = Data()
        // Header: magic, method=deflate(8), no flags, mtime=0,
        // XFL=0, OS=Unix(3). Mtime=0 keeps output reproducible.
        out.append(contentsOf: [0x1F, 0x8B, 0x08, 0x00,
                                0x00, 0x00, 0x00, 0x00,
                                0x00, 0x03])
        // DEFLATE body.
        out.append(deflate(src))
        // Trailer: CRC32 + ISIZE, both little-endian.
        appendLE32(crc32(src), to: &out)
        appendLE32(UInt32(truncatingIfNeeded: src.count), to: &out)
        return out
    }

    static func decode(_ src: Data) throws -> Data {
        guard src.count >= 18 else { throw Error.truncated }
        guard src[0] == 0x1F, src[1] == 0x8B else { throw Error.notGzip }
        guard src[2] == 0x08 else { throw Error.unsupportedMethod }
        let flags = src[3]
        var pos = 10

        if flags & 0x04 != 0 {  // FEXTRA: 2-byte length + that many bytes
            guard pos + 2 <= src.count else { throw Error.truncated }
            let xlen = Int(src[pos]) | (Int(src[pos + 1]) << 8)
            pos += 2 + xlen
        }
        if flags & 0x08 != 0 {  // FNAME: NUL-terminated original filename
            pos = try readUntilNul(src, from: pos)
        }
        if flags & 0x10 != 0 {  // FCOMMENT: NUL-terminated comment
            pos = try readUntilNul(src, from: pos)
        }
        if flags & 0x02 != 0 {  // FHCRC: 2-byte header CRC
            pos += 2
        }
        guard pos + 8 <= src.count else { throw Error.truncated }

        let bodyEnd = src.count - 8
        let body = Data(src[pos..<bodyEnd])
        // ISIZE is the original size mod 2^32; for our (memory-bounded)
        // inputs that's a reliable hint for the destination buffer.
        let isize = readLE32(src, at: src.count - 4)
        return try inflate(body, expectedSize: Int(isize))
    }

    /// Strip a leading `.gz` (or `.tgz` → `.tar`) extension to match
    /// what GNU `gunzip` writes when not using `-c`.
    static func strippedSuffix(_ path: String) -> String {
        if path.hasSuffix(".gz") { return String(path.dropLast(3)) }
        if path.hasSuffix(".tgz") {
            return String(path.dropLast(4)) + ".tar"
        }
        // No known suffix → append `.out` to avoid clobbering input.
        return path + ".out"
    }

    // MARK: DEFLATE wrappers (zlib's `deflate` / `inflate`)
    //
    // We pass `windowBits = -15` to both init calls: zlib's "raw"
    // mode that produces / consumes a bare DEFLATE bitstream, no
    // zlib (RFC 1950) framing. The gzip header / CRC32 / ISIZE we
    // generate ourselves above so the bytes match what `gzip -c`
    // would write.

    private static func deflate(_ src: Data) -> Data {
        if src.isEmpty {
            // zlib produces 3 bytes for empty input (block-of-no-data
            // marker). Match the canonical 2-byte form gzip emits so
            // round-trip through gunzip stays compact.
            return Data([0x03, 0x00])
        }
        var stream = z_stream()
        // -15 windowBits + Z_DEFLATED + default mem level + default
        // strategy. `deflateInit2_` is the variant that takes
        // ZLIB_VERSION + sizeof(z_stream) for ABI safety; the macro
        // form `deflateInit2` isn't available across the C bridge.
        let initRC = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
            -15, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initRC == Z_OK else { return Data() }
        defer { deflateEnd(&stream) }

        // Cap the destination buffer generously — `deflateBound`
        // gives the worst-case post-DEFLATE size for any input.
        // `deflateBound` takes `uLong` (size_t-ish); `src.count` is
        // already an `Int` which converts directly.
        let cap = Int(deflateBound(&stream, uLong(src.count)))
        var dst = Data(count: cap)
        let written = src.withUnsafeBytes { srcPtr -> Int in
            dst.withUnsafeMutableBytes { dstPtr -> Int in
                stream.next_in = UnsafeMutablePointer(mutating:
                    srcPtr.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in = uInt(src.count)
                stream.next_out = dstPtr.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(cap)
                let rc = zlib_deflate(&stream, Z_FINISH)
                guard rc == Z_STREAM_END else { return 0 }
                return Int(stream.total_out)
            }
        }
        return dst.prefix(written)
    }

    private static func inflate(_ src: Data,
                                expectedSize: Int) throws -> Data {
        if src.isEmpty || (src.count == 2 && src[src.startIndex] == 0x03) {
            return Data()
        }
        var stream = z_stream()
        let initRC = inflateInit2_(
            &stream, -15,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initRC == Z_OK else { throw Error.inflateFailed }
        defer { inflateEnd(&stream) }

        // Start at the size hint from the gzip ISIZE field, grow
        // geometrically if zlib fills the buffer (`ISIZE` is mod 2^32
        // so very large inputs need multiple expansions).
        var cap = max(expectedSize, 64)
        var consumedIn: uInt = 0
        for _ in 0..<32 {
            var dst = Data(count: cap)
            let result: (rc: Int32, total: Int) = src.withUnsafeBytes { srcPtr in
                dst.withUnsafeMutableBytes { dstPtr in
                    stream.next_in = UnsafeMutablePointer(mutating:
                        srcPtr.bindMemory(to: Bytef.self).baseAddress!
                            .advanced(by: Int(consumedIn)))
                    stream.avail_in = uInt(src.count) - consumedIn
                    stream.next_out = dstPtr.bindMemory(to: Bytef.self).baseAddress!
                    stream.avail_out = uInt(cap)
                    let r = zlib_inflate(&stream, Z_NO_FLUSH)
                    return (r, Int(stream.total_out))
                }
            }
            switch result.rc {
            case Z_STREAM_END:
                return dst.prefix(result.total)
            case Z_OK, Z_BUF_ERROR:
                // Need more output space — grow and retry. Track
                // input consumption so the next pass continues from
                // the right offset.
                consumedIn = uInt(src.count) - stream.avail_in
                cap *= 2
            default:
                throw Error.inflateFailed
            }
        }
        throw Error.inflateFailed
    }

    /// Tiny aliases so the source above doesn't collide with the
    /// `deflate` / `inflate` static methods on `Gzip` itself.
    private static let zlib_deflate = CZlib.deflate
    private static let zlib_inflate = CZlib.inflate

    // MARK: Header bytes

    private static func readUntilNul(_ data: Data,
                                     from start: Int) throws -> Int {
        var i = start
        while i < data.count, data[i] != 0 { i += 1 }
        guard i < data.count else { throw Error.truncated }
        return i + 1  // skip the NUL itself
    }

    private static func appendLE32(_ v: UInt32, to out: inout Data) {
        out.append(UInt8(truncatingIfNeeded: v))
        out.append(UInt8(truncatingIfNeeded: v >> 8))
        out.append(UInt8(truncatingIfNeeded: v >> 16))
        out.append(UInt8(truncatingIfNeeded: v >> 24))
    }

    private static func readLE32(_ data: Data, at off: Int) -> UInt32 {
        UInt32(data[off])
            | (UInt32(data[off + 1]) << 8)
            | (UInt32(data[off + 2]) << 16)
            | (UInt32(data[off + 3]) << 24)
    }

    // MARK: CRC32 (IEEE 802.3 polynomial — what gzip / zip / PNG use)

    private static let crc32Table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = (crc >> 8)
                ^ crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFFFFFF
    }
}
func runGzip(decompress: Bool,
                     toStdout: Bool,
                     files: [String],
                     commandName: String) async throws -> ExitStatus {
    if files.isEmpty {
        let input = await Shell.current.stdin.readAllData()
        do {
            let output = decompress
                ? try Gzip.decode(input)
                : Gzip.encode(input)
            Shell.current.stdout(output)
        } catch let err as Gzip.Error {
            Shell.current.stderr("\(commandName): \(err)\n")
            return .failure
        }
        return .success
    }

    var hadError = false
    for f in files {
        try Task.checkCancellation()
        let data: Data
        do {
            data = try await Shell.current.readDataAtPath(f)
        } catch {
            Shell.current.stderr("\(commandName): \(f): \(error)\n")
            hadError = true
            continue
        }
        let output: Data
        do {
            output = decompress ? try Gzip.decode(data) : Gzip.encode(data)
        } catch let err as Gzip.Error {
            Shell.current.stderr("\(commandName): \(f): \(err)\n")
            hadError = true
            continue
        } catch {
            Shell.current.stderr("\(commandName): \(f): \(error)\n")
            hadError = true
            continue
        }

        if toStdout {
            Shell.current.stdout(output)
        } else {
            // File replacement: write the new path, remove the old.
            let target = decompress
                ? Gzip.strippedSuffix(f)
                : f + ".gz"
            do {
                try await Shell.current.writeData(
                    output, toPath: target, append: false)
                try await Shell.current.fileSystem.remove(
                    Shell.current.resolvePath(f), recursive: false)
            } catch {
                Shell.current.stderr("\(commandName): \(f): \(error)\n")
                hadError = true
            }
        }
    }
    return hadError ? .failure : .success
}
