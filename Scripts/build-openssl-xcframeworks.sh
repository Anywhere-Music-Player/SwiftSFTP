#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSSL_SOURCE_DIR="${OPENSSL_SOURCE_DIR:-"$ROOT_DIR/vendor/openssl"}"
OUTPUT_DIR="${OPENSSL_OUTPUT_DIR:-"$ROOT_DIR/Artifacts/OpenSSL"}"
BUILD_DIR="${OPENSSL_BUILD_DIR:-"$ROOT_DIR/.openssl-build"}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
BUILD_INTEL_MAC=0
BUILD_INTEL_SIM=0
OPENSSL_VERSION="4.0.2"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--intelMac] [--intelSim]

Build OpenSSL XCFrameworks for SwiftPM as dynamic frameworks.

libcrypto/libssl are compiled the same way as before (static archives per
slice), then linked into hidden-by-default dynamic libraries that export
only OpenSSL's own documented public API (derived from
vendor/openssl/util/lib{crypto,ssl}.num), wrapped as .framework bundles.
This keeps our OpenSSL symbols out of a consuming app's flat/global export
surface and off the two-level-namespace collision path with any other
statically-linked crypto library (e.g. BoringSSL) the app also embeds.

Options:
  --intelMac  Include x86_64 macOS.
  --intelSim  Include x86_64 simulator slices.
  -h, --help  Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --intelMac)
      BUILD_INTEL_MAC=1
      ;;
    --intelSim)
      BUILD_INTEL_SIM=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ ! -f "$OPENSSL_SOURCE_DIR/Configure" ]]; then
  echo "OpenSSL source not found at $OPENSSL_SOURCE_DIR" >&2
  echo "Run: git submodule update --init --recursive vendor/openssl" >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/OpenSSLCrypto.xcframework" "$OUTPUT_DIR/OpenSSLSSL.xcframework"

# ---------------------------------------------------------------------------
# Stage 1: compile libcrypto.a / libssl.a per (platform, arch), exactly as
# before. These static archives are never shipped themselves; they are only
# used below as `-force_load` input to build a hidden-visibility dylib.
# ---------------------------------------------------------------------------

build_one() {
  local name="$1"
  local target="$2"
  local min_version_flag="$3"
  local work_dir="$BUILD_DIR/src-$name"
  local install_dir="$BUILD_DIR/install-$name"

  rsync -a --delete --exclude .git "$OPENSSL_SOURCE_DIR/" "$work_dir/"
  (
    cd "$work_dir"
    perl Configure "$target" no-shared no-module no-tests no-apps no-docs "$min_version_flag" --prefix="$install_dir"
    make -j"$JOBS"
    make install_sw
  )
}

build_generic_one() {
  local name="$1"
  local sdk="$2"
  local arch="$3"
  local target="$4"
  local min_version_flag="$5"
  local work_dir="$BUILD_DIR/src-$name"
  local install_dir="$BUILD_DIR/install-$name"
  local cflags="-arch $arch"

  if [[ -n "$min_version_flag" ]]; then
    cflags="$cflags $min_version_flag"
  fi

  rsync -a --delete --exclude .git "$OPENSSL_SOURCE_DIR/" "$work_dir/"
  (
    cd "$work_dir"
    CC="xcrun -sdk $sdk cc" CFLAGS="$cflags" perl Configure \
      "$target" no-asm no-shared no-tests no-apps no-docs \
      no-module \
      --prefix="$install_dir"
    make -j"$JOBS"
    make install_sw
  )
}

# Keep these in sync with Package.swift platforms (object minOS must be ≤ package mins).
build_one macos-arm64 darwin64-arm64-cc -mmacosx-version-min=11.0
if [[ "$BUILD_INTEL_MAC" -eq 1 ]]; then
  build_one macos-x86_64 darwin64-x86_64-cc -mmacosx-version-min=11.0
fi
build_one iphoneos-arm64 ios64-xcrun -miphoneos-version-min=14.0
build_one iphonesimulator-arm64 iossimulator-arm64-xcrun -mios-simulator-version-min=14.0
if [[ "$BUILD_INTEL_SIM" -eq 1 ]]; then
  build_one iphonesimulator-x86_64 iossimulator-x86_64-xcrun -mios-simulator-version-min=14.0
fi
build_generic_one xros-arm64 xros arm64 BSD-generic64 -mtargetos=xros1.0
build_generic_one xrsimulator-arm64 xrsimulator arm64 BSD-generic64 -mtargetos=xros1.0-simulator
if [[ "$BUILD_INTEL_SIM" -eq 1 ]]; then
  build_generic_one xrsimulator-x86_64 xrsimulator x86_64 BSD-generic64 -mtargetos=xros1.0-simulator
fi
build_generic_one watchos-arm64_32 watchos arm64_32 BSD-generic32 -mwatchos-version-min=7.0
build_generic_one watchos-arm64 watchos arm64 BSD-generic64 -mwatchos-version-min=7.0
build_generic_one watchsimulator-arm64 watchsimulator arm64 BSD-generic64 -mwatchos-simulator-version-min=7.0
if [[ "$BUILD_INTEL_SIM" -eq 1 ]]; then
  build_generic_one watchsimulator-x86_64 watchsimulator x86_64 BSD-generic64 -mwatchos-simulator-version-min=7.0
fi

# ---------------------------------------------------------------------------
# Stage 2: derive, per static archive, the set of symbols that are actually
# part of OpenSSL's own public API (vendor/openssl/util/lib{crypto,ssl}.num
# lists every symbol OpenSSL itself has ever exported as public, across its
# whole history) AND are actually defined in that archive. Everything else
# defined in the archive is an internal implementation detail that never
# needed to be global in the first place (OPENSSL_EXPORT is a plain `extern`
# on non-Windows, so the static archives export ~8,800 global symbols with no
# distinction between "public API" and "internal helper").
# ---------------------------------------------------------------------------

export_list_for() {
  local num_file="$1"
  local archive="$2"
  local out_file="$3"
  local public_tmp defined_tmp

  public_tmp="$(mktemp)"
  defined_tmp="$(mktemp)"
  awk '$4 ~ /^EXIST/ {print "_"$1}' "$num_file" | sort -u >"$public_tmp"
  nm -g "$archive" 2>/dev/null | awk '$2=="T"{print $3}' | sort -u >"$defined_tmp"
  comm -12 "$public_tmp" "$defined_tmp" >"$out_file"
  rm -f "$public_tmp" "$defined_tmp"

  if [[ ! -s "$out_file" ]]; then
    echo "No exportable symbols found for $archive against $num_file" >&2
    exit 1
  fi
}

# libssl.a references a small number of libcrypto internals that are not on
# OpenSSL's own public API list (WPACKET buffer helpers, SipHash, the
# thread/condvar helpers, a few QUIC/time helpers) - real cross-TU calls
# within upstream OpenSSL, not something we invented. Since libssl links
# against the libcrypto *dylib* (see build_slice_pair) rather than
# force-loading it again, those specific symbols must also be exported from
# OpenSSLCrypto, or the libssl link fails. This computes exactly that set:
# every symbol libssl.a leaves undefined that libcrypto.a actually defines.
extra_exports_for_ssl_dependency() {
  local ssl_archive="$1"
  local crypto_archive="$2"
  local out_file="$3"
  local undef_tmp defined_tmp

  undef_tmp="$(mktemp)"
  defined_tmp="$(mktemp)"
  nm -u "$ssl_archive" 2>/dev/null | awk '{print $1}' | sort -u >"$undef_tmp"
  nm -g "$crypto_archive" 2>/dev/null | awk '$2=="T"{print $3}' | sort -u >"$defined_tmp"
  comm -12 "$undef_tmp" "$defined_tmp" >"$out_file"
  rm -f "$undef_tmp" "$defined_tmp"
}

# ---------------------------------------------------------------------------
# Stage 3: link a hidden-by-default dynamic library from the static archive.
# `-force_load` pulls in every object file (a plain archive link would only
# pull objects that satisfy an existing undefined symbol, and a fresh dylib
# has none). `-exported_symbols_list` then demotes every global symbol NOT
# on the curated list to a local/private-extern symbol in the final Mach-O -
# it cannot promote a symbol compiled with hidden visibility back to
# external, but it can freely hide symbols that were compiled with ordinary
# (default) visibility, which is exactly what these archives contain.
# ---------------------------------------------------------------------------

link_dylib() {
  local sdk="$1"
  local arch="$2"
  local min_flag="$3"
  local install_name="$4"
  local export_list="$5"
  local out_dylib="$6"
  local link_against_dylib="$7"
  shift 7
  local force_load_archives=("$@")

  local force_load_flags=()
  local archive
  for archive in "${force_load_archives[@]}"; do
    force_load_flags+=(-Wl,-force_load,"$archive")
  done

  # bash 3.2 (macOS's default /bin/bash) treats `"${arr[@]}"` on a still-empty
  # array as an unbound-variable error under `set -u`, so this optional extra
  # link input is passed via parameter expansion instead of a second array.
  # shellcheck disable=SC2086
  xcrun -sdk "$sdk" clang -arch "$arch" $min_flag -dynamiclib \
    "${force_load_flags[@]}" \
    ${link_against_dylib:+"$link_against_dylib"} \
    -install_name "$install_name" \
    -current_version "$OPENSSL_VERSION" \
    -compatibility_version "$OPENSSL_VERSION" \
    -exported_symbols_list "$export_list" \
    -o "$out_dylib"
}

# ---------------------------------------------------------------------------
# Stage 4: XCFrameworks ship OpenSSLCrypto/OpenSSLSSL as plain dynamic
# libraries (`-library x.dylib -headers include/`), the same shape as the
# static archives they replace - NOT wrapped in a `.framework` bundle.
#
# That is a deliberate choice, not a shortcut: SwiftPM only adds a `-F`
# framework search path for a `.framework`-kind XCFramework slice, not a
# plain `-I` header search path. libssh2's vendored `openssl.h` does
# `#include <openssl/opensslv.h>` (bare, non-framework-qualified), which
# needs `-I`; that only gets added for a `library`-kind XCFramework slice
# (`AvailableLibraries[].LibraryPath` pointing at a `.dylib`/`.a` next to a
# `HeadersPath`). A `.framework`-wrapped OpenSSLCrypto compiles fine for
# Swift's `import OpenSSLCrypto` but fails every libssh2 C translation unit
# with "'openssl/opensslv.h' file not found" - verified empirically before
# settling on this layout. The install name is a flat `@rpath/<file>.dylib`
# to match: SwiftPM copies a library-kind XCFramework's dylib straight into
# the product output directory (no `Name.framework/` subpath), and the
# executable's `@loader_path` rpath entry resolves it from there.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Stage 5: build one dylib pair (crypto, ssl) per arch, lipo same-platform
# archs together, wrap into frameworks, and finally assemble both
# XCFrameworks. `libssl`'s dylib links against the `libcrypto` dylib built
# just before it in the same slice (matching upstream OpenSSL's own
# libssl -> libcrypto dependency), rather than force-loading and duplicating
# libcrypto's ~5MB of object code into every slice a second time.
# OpenSSLSSL is not consumed by any target today (same as before this
# change), so this only affects a currently-unused artifact.
# ---------------------------------------------------------------------------

CRYPTO_NUM="$OPENSSL_SOURCE_DIR/util/libcrypto.num"
SSL_NUM="$OPENSSL_SOURCE_DIR/util/libssl.num"

# build_slice_pair <group> <sdk> <min_flag> <name1:arch1> [<name2:arch2> ...]
# `name` is the directory suffix used by build_one/build_generic_one above
# (e.g. "watchos-arm64_32"); `arch` is the -arch value to pass to the linker.
# Most groups have a single arch; macOS/simulators optionally gain x86_64
# (--intelMac/--intelSim), and watchOS device always ships two (arm64_32 +
# arm64, for old vs. new Watches) lipo'd into one Mach-O slice.
build_slice_pair() {
  local group="$1" sdk="$2" min_flag="$3"
  shift 3
  local pairs=("$@")

  local crypto_dylibs=()
  local ssl_dylibs=()
  local first_name=""
  local pair name arch

  for pair in "${pairs[@]}"; do
    name="${pair%%:*}"
    arch="${pair#*:}"
    if [[ -z "$first_name" ]]; then
      first_name="$name"
    fi

    local install_dir="$BUILD_DIR/install-$name"
    local crypto_archive="$install_dir/lib/libcrypto.a"
    local ssl_archive="$install_dir/lib/libssl.a"

    local crypto_public_exports="$BUILD_DIR/exports-crypto-public-$name.txt"
    local crypto_extra_exports="$BUILD_DIR/exports-crypto-extra-$name.txt"
    local crypto_exports="$BUILD_DIR/exports-crypto-$name.txt"
    local ssl_exports="$BUILD_DIR/exports-ssl-$name.txt"
    export_list_for "$CRYPTO_NUM" "$crypto_archive" "$crypto_public_exports"
    export_list_for "$SSL_NUM" "$ssl_archive" "$ssl_exports"
    extra_exports_for_ssl_dependency "$ssl_archive" "$crypto_archive" "$crypto_extra_exports"
    sort -u "$crypto_public_exports" "$crypto_extra_exports" >"$crypto_exports"

    local crypto_dylib="$BUILD_DIR/dylib-crypto-$name.dylib"
    local ssl_dylib="$BUILD_DIR/dylib-ssl-$name.dylib"

    link_dylib "$sdk" "$arch" "$min_flag" \
      "@rpath/libcrypto.dylib" "$crypto_exports" "$crypto_dylib" "" \
      "$crypto_archive"

    # libssl.a leaves a handful of non-public-API libcrypto symbols undefined
    # (see extra_exports_for_ssl_dependency above); those are now exported
    # from the crypto dylib specifically so libssl can link against it
    # directly instead of force-loading (and duplicating) libcrypto again.
    link_dylib "$sdk" "$arch" "$min_flag" \
      "@rpath/libssl.dylib" "$ssl_exports" "$ssl_dylib" "$crypto_dylib" \
      "$ssl_archive"

    crypto_dylibs+=("$crypto_dylib")
    ssl_dylibs+=("$ssl_dylib")
  done

  # Stage this group's slice exactly like the previous static artifact did:
  # <group>/lib/{libcrypto,libssl}.dylib next to <group>/include (headers are
  # arch-independent within a group, so the first arch's copy is reused).
  local slice_dir="$BUILD_DIR/slice-$group"
  mkdir -p "$slice_dir/lib"
  rsync -a "$BUILD_DIR/install-$first_name/include" "$slice_dir/"

  if [[ "${#crypto_dylibs[@]}" -eq 1 ]]; then
    cp "${crypto_dylibs[0]}" "$slice_dir/lib/libcrypto.dylib"
    cp "${ssl_dylibs[0]}" "$slice_dir/lib/libssl.dylib"
  else
    lipo -create "${crypto_dylibs[@]}" -output "$slice_dir/lib/libcrypto.dylib"
    lipo -create "${ssl_dylibs[@]}" -output "$slice_dir/lib/libssl.dylib"
  fi
}

MACOS_PAIRS=("macos-arm64:arm64")
if [[ "$BUILD_INTEL_MAC" -eq 1 ]]; then
  MACOS_PAIRS+=("macos-x86_64:x86_64")
fi

IOS_SIM_PAIRS=("iphonesimulator-arm64:arm64")
if [[ "$BUILD_INTEL_SIM" -eq 1 ]]; then
  IOS_SIM_PAIRS+=("iphonesimulator-x86_64:x86_64")
fi

XROS_SIM_PAIRS=("xrsimulator-arm64:arm64")
if [[ "$BUILD_INTEL_SIM" -eq 1 ]]; then
  XROS_SIM_PAIRS+=("xrsimulator-x86_64:x86_64")
fi

WATCH_SIM_PAIRS=("watchsimulator-arm64:arm64")
if [[ "$BUILD_INTEL_SIM" -eq 1 ]]; then
  WATCH_SIM_PAIRS+=("watchsimulator-x86_64:x86_64")
fi

build_slice_pair macos macosx -mmacosx-version-min=11.0 "${MACOS_PAIRS[@]}"
build_slice_pair iphoneos iphoneos -miphoneos-version-min=14.0 "iphoneos-arm64:arm64"
build_slice_pair iphonesimulator iphonesimulator -mios-simulator-version-min=14.0 "${IOS_SIM_PAIRS[@]}"
build_slice_pair xros xros -mtargetos=xros1.0 "xros-arm64:arm64"
build_slice_pair xrsimulator xrsimulator -mtargetos=xros1.0-simulator "${XROS_SIM_PAIRS[@]}"
# watchOS device always ships both archs (arm64_32 for older Watches, arm64
# for Watch Ultra/Series 9+), lipo'd into one Mach-O slice.
build_slice_pair watchos watchos -mwatchos-version-min=7.0 "watchos-arm64_32:arm64_32" "watchos-arm64:arm64"
build_slice_pair watchsimulator watchsimulator -mwatchos-simulator-version-min=7.0 "${WATCH_SIM_PAIRS[@]}"

xcodebuild -create-xcframework \
  -library "$BUILD_DIR/slice-macos/lib/libcrypto.dylib" -headers "$BUILD_DIR/slice-macos/include" \
  -library "$BUILD_DIR/slice-iphoneos/lib/libcrypto.dylib" -headers "$BUILD_DIR/slice-iphoneos/include" \
  -library "$BUILD_DIR/slice-iphonesimulator/lib/libcrypto.dylib" -headers "$BUILD_DIR/slice-iphonesimulator/include" \
  -library "$BUILD_DIR/slice-xros/lib/libcrypto.dylib" -headers "$BUILD_DIR/slice-xros/include" \
  -library "$BUILD_DIR/slice-xrsimulator/lib/libcrypto.dylib" -headers "$BUILD_DIR/slice-xrsimulator/include" \
  -library "$BUILD_DIR/slice-watchos/lib/libcrypto.dylib" -headers "$BUILD_DIR/slice-watchos/include" \
  -library "$BUILD_DIR/slice-watchsimulator/lib/libcrypto.dylib" -headers "$BUILD_DIR/slice-watchsimulator/include" \
  -output "$OUTPUT_DIR/OpenSSLCrypto.xcframework"

xcodebuild -create-xcframework \
  -library "$BUILD_DIR/slice-macos/lib/libssl.dylib" -headers "$BUILD_DIR/slice-macos/include" \
  -library "$BUILD_DIR/slice-iphoneos/lib/libssl.dylib" -headers "$BUILD_DIR/slice-iphoneos/include" \
  -library "$BUILD_DIR/slice-iphonesimulator/lib/libssl.dylib" -headers "$BUILD_DIR/slice-iphonesimulator/include" \
  -library "$BUILD_DIR/slice-xros/lib/libssl.dylib" -headers "$BUILD_DIR/slice-xros/include" \
  -library "$BUILD_DIR/slice-xrsimulator/lib/libssl.dylib" -headers "$BUILD_DIR/slice-xrsimulator/include" \
  -library "$BUILD_DIR/slice-watchos/lib/libssl.dylib" -headers "$BUILD_DIR/slice-watchos/include" \
  -library "$BUILD_DIR/slice-watchsimulator/lib/libssl.dylib" -headers "$BUILD_DIR/slice-watchsimulator/include" \
  -output "$OUTPUT_DIR/OpenSSLSSL.xcframework"

# Add a modulemap to each OpenSSLCrypto slice so Swift targets can import it
# (Swift code does `import OpenSSLCrypto`; OpenSSLSSL has no Swift/C
# consumer today, same as before this change, so it gets no module map).
for slice_dir in "$OUTPUT_DIR/OpenSSLCrypto.xcframework"/*/Headers; do
  cat >"$slice_dir/module.modulemap" <<'MMAP'
module OpenSSLCrypto {
    // `macros.h` includes `opensslconf.h` (OpenSSL 4.0 onwards; 4.1.0-dev reached `configuration.h`
    // directly). With `opensslconf.h` modular and `macros.h` textual, the module's copy of `macros.h`
    // exports `OPENSSL_API_LEVEL` back into the textual pass, which then trips the
    // "must not be defined by application" guard. Keeping all four in the module avoids the mix.
    header "openssl/configuration.h"
    header "openssl/macros.h"
    header "openssl/opensslv.h"
    header "openssl/opensslconf.h"
    header "openssl/ossl_typ.h"
    header "openssl/obj_mac.h"
    header "openssl/bio.h"
    header "openssl/evp.h"
    header "openssl/pem.h"
    header "openssl/err.h"
    header "openssl/crypto.h"
    header "openssl/core.h"
    header "openssl/core_names.h"
    header "openssl/params.h"
    header "openssl/types.h"
    header "openssl/asn1.h"
    header "openssl/x509.h"
    header "openssl/rsa.h"
    header "openssl/ec.h"
    export *
}
MMAP
done

echo "Built dynamic OpenSSL XCFrameworks in $OUTPUT_DIR"
