#!/usr/bin/env bash
#
# Fetch and stage Bun's prebuilt JavaScriptCore static archive
# (oven-sh/WebKit autobuild) under Vendor/bun-webkit/<triple>/, then
# point Vendor/bun-webkit/current at it. Package.swift uses that
# `current` symlink as the include / library search root for the
# CJavaScriptCore C target on Linux / Windows / Android.
#
# Apple platforms don't need this — they use the system
# JavaScriptCore.framework via Swift's `import JavaScriptCore`. The
# script will refuse to run on Darwin to avoid confusion.
#
# Pinned to a specific autobuild commit so SwiftBash builds are
# reproducible. Bump WEBKIT_VERSION when picking up a newer JSC.
#
# Override knobs:
#   BUN_WEBKIT_VERSION       autobuild commit SHA
#   BUN_WEBKIT_ASSET         exact tarball name (skips host detection)
#   BUN_WEBKIT_VARIANT       `release` (default) | `lto` | `baseline`
#   BUN_WEBKIT_ROOT          where to stage (default: Vendor/bun-webkit)
#
# See Docs/SwiftJS.md § Cross-platform for design rationale.
set -euo pipefail

WEBKIT_VERSION="${BUN_WEBKIT_VERSION:-88b2f7a2159c913f7dd0d73c0e88d66138cd67ba}"
VARIANT="${BUN_WEBKIT_VARIANT:-release}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage_root="${BUN_WEBKIT_ROOT:-$repo_root/Vendor/bun-webkit}"

# ---- Asset selection -------------------------------------------------------

detect_asset() {
    local os arch libc=""
    case "$(uname -s)" in
        Linux)   os="linux" ;;
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        Darwin)
            echo "fetch-bun-webkit: refusing to run on Darwin —" \
                 "Apple platforms use the system JavaScriptCore" \
                 "framework, not bun-webkit." >&2
            exit 64
            ;;
        *) echo "fetch-bun-webkit: unsupported OS '$(uname -s)'" >&2
           exit 1 ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)   arch="amd64" ;;
        aarch64|arm64)  arch="arm64" ;;
        *) echo "fetch-bun-webkit: unsupported arch '$(uname -m)'" >&2
           exit 1 ;;
    esac

    # Linux glibc vs musl — the tarballs are link-incompatible
    # because libc++ on each side has a different C++ ABI. We
    # check `ldd --version` for a "musl" banner, but musl's ldd
    # commonly exits non-zero (it has no `--version` flag and
    # prints help to stderr instead). With `set -o pipefail` that
    # would poison `ldd ... | grep -qi musl` and we'd select the
    # wrong tarball. The `{ ...; || true; }` group neutralises the
    # exit status before the pipe so grep's status alone decides.
    if [[ "$os" == "linux" ]]; then
        if { ldd --version 2>&1 || true; } | grep -qi musl \
            || [[ -f /etc/alpine-release ]]; then
            libc="-musl"
        fi
        # Android (Bionic) detection: `uname -o` returns "Android"
        # on Termux / Bionic devices but "GNU/Linux" on glibc and
        # "Linux" on musl. Don't sniff `ANDROID_NDK_ROOT` etc. —
        # GitHub's `ubuntu-latest` runner ships the NDK preinstalled
        # and exports those vars, which mis-routed the Linux CI
        # job to the Android-target tarball. Cross-builds (host
        # = Linux, target = Android) must set `BUN_WEBKIT_ASSET`
        # explicitly; the workflow's Android job does so.
        if [[ "$(uname -o 2>/dev/null || true)" == "Android" ]]; then
            libc="-android"
        fi
    fi

    local suffix=""
    case "$VARIANT" in
        release)  suffix="" ;;
        lto)      suffix="-lto" ;;
        baseline) suffix="-baseline" ;;
        *) echo "fetch-bun-webkit: unknown variant '$VARIANT'" >&2
           exit 1 ;;
    esac

    echo "bun-webkit-${os}-${arch}${libc}${suffix}.tar.gz"
}

asset="${BUN_WEBKIT_ASSET:-$(detect_asset)}"
triple="${asset#bun-webkit-}"
triple="${triple%.tar.gz}"

stage_dir="$stage_root/$triple-$WEBKIT_VERSION"
extracted_marker="$stage_dir/.fetched"

# ---- Stage cache hit -------------------------------------------------------

if [[ -f "$extracted_marker" ]]; then
    echo "fetch-bun-webkit: cache hit ($triple @ ${WEBKIT_VERSION:0:12})"
else
    url="https://github.com/oven-sh/WebKit/releases/download/autobuild-${WEBKIT_VERSION}/${asset}"
    echo "fetch-bun-webkit: downloading $asset"
    echo "                  from $url"

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    # -L follows redirects to the release CDN. --fail surfaces 404
    # as a non-zero exit instead of saving the HTML error page.
    curl --fail --location --silent --show-error \
         --output "$tmp/$asset" "$url"

    mkdir -p "$stage_dir"
    # The tarball top-level directory is `bun-webkit/`. Strip it so
    # we end up with bin/, lib/, include/ directly under $stage_dir.
    tar -xzf "$tmp/$asset" -C "$stage_dir" --strip-components=1
    touch "$extracted_marker"
    echo "fetch-bun-webkit: extracted to $stage_dir"
fi

# ---- Sanity check ----------------------------------------------------------

case "$triple" in
    windows-*) ext="lib"; prefix="" ;;
    *)         ext="a";   prefix="lib" ;;
esac

required_lib="$stage_dir/lib/${prefix}JavaScriptCore.${ext}"
required_hdr="$stage_dir/include/JavaScriptCore/JavaScript.h"

for f in "$required_lib" "$required_hdr"; do
    if [[ ! -f "$f" ]]; then
        echo "fetch-bun-webkit: expected file missing: $f" >&2
        echo "                  the tarball layout may have changed" >&2
        echo "                  (asset: $asset)" >&2
        exit 1
    fi
done

# ---- current symlink -------------------------------------------------------

current="$stage_root/current"
# Refresh the symlink unconditionally so a re-run after VARIANT or
# WEBKIT_VERSION changes ends up pointing at the right stage dir.
rm -f "$current"
ln -s "$(basename "$stage_dir")" "$current"

echo "fetch-bun-webkit: $current -> $(basename "$stage_dir")"
echo "fetch-bun-webkit: ready"
