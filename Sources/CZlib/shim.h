// Single header shim — pulls in the host zlib's public surface
// (deflate / inflate / crc32 / adler32 / gzopen / …) for the
// `import CZlib` consumers in BashCommandKit/Gzip.swift.
#include <zlib.h>
