// mimalloc, for JavaScriptCore on Linux and Android.
//
// Bun's bun-webkit archives built since July 2026 (oven-sh/WebKit#283,
// USE_EXTERNAL_MIMALLOC) carry no allocator of their own: bmalloc calls
// mi_malloc, mi_free, mi_heap_new_in_arena, mi_theap_*, … and expects the
// program that links the archive to provide mimalloc. Bun links its fork,
// oven-sh/mimalloc, at the commit it pairs with each WebKit pin.
// `scripts/fetch-bun-webkit.sh` stages that commit's sources under
// Vendor/bun-webkit/current/mimalloc/, and this file compiles mimalloc's
// unity translation unit the way Bun does (scripts/build/deps/mimalloc.ts in
// oven-sh/bun): `src/static.c` alone, as C++, with the defines in
// Package.swift. Unlike Bun it doesn't replace the process's malloc: only
// JavaScriptCore allocates through mimalloc; the host's malloc stays as is.
//
// Elsewhere (Apple platforms use the system JavaScriptCore; Windows doesn't
// link JavaScriptCore yet) this translation unit is empty.
#if defined(__linux__) && __has_include("static.c")
#include "static.c"
#endif
