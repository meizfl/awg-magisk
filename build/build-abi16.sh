#!/usr/bin/env bash
# build-abi16.sh - cross-compiles awg, awg-quick and amneziawg-go for
# Android (bionic libc) targeting API 16-17 (Android 4.1-4.2, Jelly Bean)
# and lays out the result under the module's bin/arch/<arch>/, then
# packages the final Magisk-flashable zip via package-abi16.sh.
#
# Requirements on the build machine:
#   - bash, curl or wget, unzip, git
#   - Go >= 1.21 (to build amneziawg-go)
#   - internet access to github.com and dl.google.com (for the Android NDK)
#
# Usage:
#   ./build-abi16.sh                  # builds arm, x86 (this ABI range predates arm64/x86_64)
#   ./build-abi16.sh arm               # armeabi-v7a only
#   API_LEVEL=17 ./build-abi16.sh arm  # narrower target within the same range
#
# IMPORTANT notes on this API range:
#   - Google's documented NDK r23+ floor is API 21, but empirically r23c's
#     clang still accepts and compiles/links lower target-triple levels
#     (verified down to 16) as long as no libc symbol actually missing at
#     that level gets referenced. Treat anything below 21 as
#     unofficial/best-effort and verify per NDK version.
#   - getline()/getdelim() were only added to bionic in API level 18
#     (Jelly Bean MR2) - see the bionic status docs. Below that,
#     ipc-uapi.h, setconf.c and wg-quick/android.c all fail to LINK with
#     "undefined symbol: getline" (the compiler only warns about an
#     implicit declaration; the actual failure surfaces at the link step).
#     This script force-includes a portable getline() shim via `-include`,
#     since API_LEVEL is always < 18 in this build variant.
#   - getentropy() is never used on Android (gated behind __GLIBC__/
#     __APPLE__ in genkey.c; on bionic it always falls through to the raw
#     getrandom syscall path), and libbinder_ndk.so is loaded via dlopen()
#     with a binder_available check - on older devices where it's missing,
#     DNS-via-Binder is simply skipped instead of crashing.
#   - arm64/x86_64 did not exist yet on API 16-17 devices, so this variant
#     only builds arm (armeabi-v7a) and x86.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$SCRIPT_DIR/.work"
NDK_VERSION="r23c"
NDK_ZIP="android-ndk-${NDK_VERSION}-linux.zip"
NDK_URL="https://dl.google.com/android/repository/${NDK_ZIP}"
API_LEVEL="${API_LEVEL:-16}"

AWG_TOOLS_REPO="https://github.com/amnezia-vpn/amneziawg-tools.git"
AWG_GO_REPO="https://github.com/amnezia-vpn/amneziawg-go.git"

ARCHES="${1:-arm x86}"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "==> [1/5] Preparing Android NDK ${NDK_VERSION}"
if [ ! -d "$WORK_DIR/android-ndk-${NDK_VERSION}" ]; then
  if [ ! -f "$NDK_ZIP" ]; then
    curl -fL -o "$NDK_ZIP" "$NDK_URL"
  fi
  unzip -q "$NDK_ZIP"
fi
NDK_HOME="$WORK_DIR/android-ndk-${NDK_VERSION}"
TOOLCHAIN="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"

echo "==> [2/5] Cloning amneziawg-tools and amneziawg-go sources"
[ -d amneziawg-tools ] || git clone --depth 1 "$AWG_TOOLS_REPO" amneziawg-tools
[ -d amneziawg-go ]    || git clone --depth 1 "$AWG_GO_REPO" amneziawg-go

# Map: our ABI name -> (Go GOARCH, clang target triple, bin/arch subdir)
declare -A GOARCH_MAP=( [arm64]=arm64 [arm]=arm [x86_64]=amd64 [x86]=386 )
declare -A CLANG_TARGET=(
  [arm64]="aarch64-linux-android${API_LEVEL}"
  [arm]="armv7a-linux-androideabi${API_LEVEL}"
  [x86_64]="x86_64-linux-android${API_LEVEL}"
  [x86]="i686-linux-android${API_LEVEL}"
)

# Where android.c looks for configs by default - matches the module id in module.prop
MODULE_ID="awg_quick_magisk"
MODDIR_ON_DEVICE="/data/adb/modules/${MODULE_ID}"
CONFIG_SEARCH_PATH="${MODDIR_ON_DEVICE}/config"

# bionic (Android's libc) does not provide the GNU strchrnul() extension
# that wg-quick/android.c uses further down (in the per-app UID selection
# code) - it's a glibc/BSD-only function, unrelated to _GNU_SOURCE, and
# unlike strchr() upstream is missing on Android. Even config.c in the same
# repo explicitly avoids it with the comment "This is what strchrnul is
# for, but that isn't portable" - looks like an oversight in android.c
# itself. Inject a portable static inline replacement right after the
# ARRAY_SIZE macro (idempotent: skipped on reruns via the marker below).
ANDROID_C="amneziawg-tools/src/wg-quick/android.c"
if [ -f "$ANDROID_C" ] && ! grep -q "AWG_MAGISK_STRCHRNUL_COMPAT" "$ANDROID_C"; then
  echo "==> Patching android.c: bionic has no strchrnul(), adding a portable shim"
  PATCH_SNIPPET="$WORK_DIR/strchrnul_compat.inc"
  cat > "$PATCH_SNIPPET" << 'SNIP'

/* AWG_MAGISK_STRCHRNUL_COMPAT: bionic (Android libc) does not provide the
 * GNU strchrnul() extension used later in this file, even with _GNU_SOURCE
 * defined - it's a glibc/BSD-only function. Portable drop-in replacement. */
static inline char *strchrnul(const char *s, int c)
{
	char *r = strchr(s, c);
	return r ? r : (char *)s + strlen(s);
}
SNIP
  ANCHOR_LINE="$(grep -n '^#define ARRAY_SIZE(x)' "$ANDROID_C" | head -1 | cut -d: -f1)"
  if [ -z "$ANCHOR_LINE" ]; then
    echo "ERROR: could not find the ARRAY_SIZE anchor in android.c - upstream layout changed?" >&2
    exit 1
  fi
  sed -i "${ANCHOR_LINE}r ${PATCH_SNIPPET}" "$ANDROID_C"
fi

# bionic only gained getline()/getdelim() in API level 18 (Jelly Bean MR2).
# Below that, ipc-uapi.h, setconf.c and wg-quick/android.c all fail to
# LINK with "undefined symbol: getline" (the compiler itself only warns
# about an implicit declaration; the real failure only shows up at the
# link step). This build variant always targets API < 18, so the shim is
# always applied here (unlike the abi18/abi21 variants, where it must NOT
# be applied - bionic already exports the real symbol there and our own
# definition would clash with it).
echo "==> API_LEVEL=$API_LEVEL < 18: bionic has no getline(), adding a portable shim"
GETLINE_COMPAT_HEADER="$WORK_DIR/getline_compat.h"
cat > "$GETLINE_COMPAT_HEADER" << 'HDR'
#ifndef AWG_MAGISK_GETLINE_COMPAT_H
#define AWG_MAGISK_GETLINE_COMPAT_H
/* AWG_MAGISK_GETLINE_COMPAT: bionic (Android libc) only gained getline()
 * in API level 18 (Jelly Bean MR2). Minimal portable implementation for
 * older targets - force-included via `-include` since this build variant
 * always targets API < 18. */
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <errno.h>

static inline ssize_t getline(char **lineptr, size_t *n, FILE *stream)
{
	size_t pos = 0;
	int c;

	if (!lineptr || !n || !stream) {
		errno = EINVAL;
		return -1;
	}
	if (!*lineptr || *n == 0) {
		*n = 128;
		*lineptr = realloc(*lineptr, *n);
		if (!*lineptr)
			return -1;
	}
	while ((c = fgetc(stream)) != EOF) {
		if (pos + 1 >= *n) {
			size_t new_size = *n * 2;
			char *new_ptr = realloc(*lineptr, new_size);
			if (!new_ptr)
				return -1;
			*lineptr = new_ptr;
			*n = new_size;
		}
		(*lineptr)[pos++] = (char)c;
		if (c == '\n')
			break;
	}
	if (pos == 0 && c == EOF)
		return -1;
	(*lineptr)[pos] = '\0';
	return (ssize_t)pos;
}
#endif
HDR
EXTRA_CFLAGS=(-include "$GETLINE_COMPAT_HEADER")

# "/" and "/var" are mounted read-only on Android, so the default UAPI
# socket path /var/run/amneziawg/<iface>.sock fails with "read-only file
# system". We move the socket into the module's own directory (on /data,
# always writable). This is a SHARED contract between the C `awg` CLI
# (RUNSTATEDIR macro, set via `make RUNSTATEDIR=...`) and the Go daemon
# amneziawg-go (ipc.socketDirectory variable, set via `-ldflags -X`,
# specifically exported for this purpose in the amneziawg-go source). Both
# must match, or `awg` won't be able to reach the daemon's socket.
RUNSTATEDIR="${MODDIR_ON_DEVICE}/run"                 # for C: SOCK_PATH = RUNSTATEDIR "/amneziawg/"
GO_SOCKET_DIR="${RUNSTATEDIR}/amneziawg"               # for Go: sockPath = socketDirectory + "/" + iface + ".sock"

# Clean previous build artifacts so we never mix ABIs / API levels
rm -rf "$MODULE_DIR/bin/arch"

for ARCH in $ARCHES; do
  echo "==> [3/6] Building awg (CLI, Makefile target is called 'wg') for $ARCH"
  CC="$TOOLCHAIN/bin/${CLANG_TARGET[$ARCH]}-clang"
  STRIP="$TOOLCHAIN/bin/llvm-strip"
  OUT_DIR="$MODULE_DIR/bin/arch/$ARCH"
  mkdir -p "$OUT_DIR"

  ( cd amneziawg-tools/src
    make clean >/dev/null 2>&1 || true
    # The real Makefile target is called "wg" (it's only renamed to awg
    # during `make install`). The device already has bionic - static
    # linking is unnecessary and often breaks under the NDK, so we build
    # a plain dynamic ELF for the Android ABI instead.
    # RUNSTATEDIR overrides the UAPI socket path (see comment above).
    # EXTRA_CFLAGS carries the getline() shim -include flag (always set
    # in this build variant, see comment above).
    CC="$CC" CFLAGS="-O2 ${EXTRA_CFLAGS[*]}" make RUNSTATEDIR="$RUNSTATEDIR" wg -j"$(nproc)"
    "$STRIP" wg -o "$OUT_DIR/awg"
  )

  echo "==> [4/6] Compiling the native awg-quick (wg-quick/android.c) for $ARCH"
  # amneziawg-tools/wireguard-tools ships a ready-made C implementation of
  # wg-quick specifically for Android (wg-quick/android.c): it brings up
  # the interface via amneziawg-go itself, configures routes/iptables and
  # DNS via android.net.IDnsResolver over Binder (dlopen'ing
  # libbinder_ndk.so at runtime, so no explicit link against libbinder is
  # needed).
  "$CC" -O2 "${EXTRA_CFLAGS[@]}" \
    -DAWG_CONFIG_SEARCH_PATHS="\"${CONFIG_SEARCH_PATH}\"" \
    "amneziawg-tools/src/wg-quick/android.c" \
    -o "$OUT_DIR/awg-quick" -ldl
  "$STRIP" "$OUT_DIR/awg-quick"

  echo "==> [5/6] Building amneziawg-go for $ARCH (GOOS=android, cgo)"
  (
    cd amneziawg-go
    export GOOS=android
    export GOARCH="${GOARCH_MAP[$ARCH]}"
    export CGO_ENABLED=1
    export CC="$TOOLCHAIN/bin/${CLANG_TARGET[$ARCH]}-clang"
    export CXX="$TOOLCHAIN/bin/${CLANG_TARGET[$ARCH]}-clang++"
    # Read the module path from go.mod dynamically (at the time of writing
    # this is github.com/amnezia-vpn/amneziawg-go/v3) so this doesn't
    # break if upstream bumps the major version.
    GOMOD_PATH="$(head -1 go.mod | awk '{print $2}')"
    go build -trimpath \
      -ldflags="-s -w -X ${GOMOD_PATH}/ipc.socketDirectory=${GO_SOCKET_DIR}" \
      -o "$OUT_DIR/amneziawg-go" .
  )

  echo "==> awg, awg-quick, amneziawg-go for $ARCH are ready in $OUT_DIR"
done

echo "==> [6/6] Copying awg-supervisor (plain POSIX sh, no compilation needed) and packaging the zip"
for ARCH in $ARCHES; do
  cp "$MODULE_DIR/bin/awg-supervisor" "$MODULE_DIR/bin/arch/$ARCH/awg-supervisor"
  chmod +x "$MODULE_DIR/bin/arch/$ARCH/"*
done

bash "$SCRIPT_DIR/package-abi16.sh"

echo "==> Done. Find the final zip under build/dist/"
