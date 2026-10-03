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

// What the C library needs, decided here because SwiftPM's `.linux`
// condition covers glibc and musl alike. glibc defines __GLIBC__ in
// <features.h>; musl defines no such macro. _DEFAULT_SOURCE is what
// static.c defines first, so it has to be set before any libc header.
#if !defined(__ANDROID__)
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif
#include <features.h>
#if !defined(__GLIBC__)
#define MI_LIBC_MUSL 1  // as mimalloc's and Bun's builds do for musl
#endif
#endif

// TLS model, per C library, as mimalloc's own CMake build and Bun's choose
// it: initial-exec on glibc, which keeps the allocation path to one GOT load
// and still works in a module loaded after startup, because glibc reserves
// spare static TLS for those; local-dynamic on musl, whose static TLS block
// is fixed, so initial-exec TLS in a shared object loaded after startup (a
// test bundle, a plugin) can fail (mimalloc #644).
// Android keeps the default; mimalloc uses pthread keys there anyway.
#if defined(__GLIBC__)
#pragma clang attribute push (__attribute__((tls_model("initial-exec"))), apply_to = variable(is_thread_local))
#elif defined(MI_LIBC_MUSL)
#pragma clang attribute push (__attribute__((tls_model("local-dynamic"))), apply_to = variable(is_thread_local))
#endif

#include "static.c"

#if defined(__GLIBC__) || defined(MI_LIBC_MUSL)
#pragma clang attribute pop
#endif

#endif
