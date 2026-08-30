#!/usr/bin/env bash
# build.sh — cross-compiles awg, awg-quick and amneziawg-go for Android
# (bionic libc) and places the result under the module's bin/arch/<arch>/,
# then packages the final Magisk-flashable zip.
#
# Requirements on the build machine:
#   - bash, curl or wget, unzip, git
#   - Go >= 1.21 (to build amneziawg-go)
#   - internet access to github.com and dl.google.com (for the Android NDK)
#
# Usage:
#   ./build.sh              # builds for all ABIs: arm64, arm, x86_64, x86
#   ./build.sh arm64         # only arm64-v8a (the most common case)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$SCRIPT_DIR/.work"
NDK_VERSION="r27c"
NDK_ZIP="android-ndk-${NDK_VERSION}-linux.zip"
NDK_URL="https://dl.google.com/android/repository/${NDK_ZIP}"
API_LEVEL=24   # Android 7.0+, a reasonable minimum for modern VPN clients

AWG_TOOLS_REPO="https://github.com/amnezia-vpn/amneziawg-tools.git"
AWG_GO_REPO="https://github.com/amnezia-vpn/amneziawg-go.git"

ARCHES="${1:-arm64 arm x86_64 x86}"

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

# Map: our ABI name -> (Go GOARCH, clang target triple, directory in bin/arch)
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

# On Android "/" and "/var" are mounted read-only, so the default UAPI socket
# path /var/run/amneziawg/<iface>.sock fails with "read-only file
# system". We move the socket into the module directory (it's on /data, always
# writable). This is a SHARED contract between the C utility awg (RUNSTATEDIR
# macro, set via `make RUNSTATEDIR=...`) and the Go daemon amneziawg-go
# (ipc.socketDirectory variable, set via `-ldflags -X`, specifically exported
# for this purpose in the amneziawg-go sources). Both must match, otherwise
# `awg` will not be able to connect to the daemon's socket.
RUNSTATEDIR="${MODDIR_ON_DEVICE}/run"                 # for C: SOCK_PATH = RUNSTATEDIR "/amneziawg/"
GO_SOCKET_DIR="${RUNSTATEDIR}/amneziawg"               # for Go: sockPath = socketDirectory + "/" + iface + ".sock"

for ARCH in $ARCHES; do
  echo "==> [3/6] Building awg (CLI, the Makefile target is called 'wg') for $ARCH"
  CC="$TOOLCHAIN/bin/${CLANG_TARGET[$ARCH]}-clang"
  STRIP="$TOOLCHAIN/bin/llvm-strip"
  OUT_DIR="$MODULE_DIR/bin/arch/$ARCH"
  mkdir -p "$OUT_DIR"

  ( cd amneziawg-tools/src
    make clean >/dev/null 2>&1 || true
    # The actual Makefile target is called "wg" (it's renamed to awg
    # only at the `make install` step). Bionic is already on the device -
    # static linking isn't needed and often breaks with the NDK, so
    # we build as a regular dynamic ELF for the Android ABI.
    # RUNSTATEDIR overrides the UAPI socket path (see the comment above).
    CC="$CC" CFLAGS="-O2" make RUNSTATEDIR="$RUNSTATEDIR" wg -j"$(nproc)"
    "$STRIP" wg -o "$OUT_DIR/awg"
  )

  echo "==> [4/6] Compiling native awg-quick (wg-quick/android.c) for $ARCH"
  # amneziawg-tools/wireguard-tools HAS a ready-made C implementation of
  # wg-quick specifically for Android (wg-quick/android.c): it brings up the
  # interface itself via amneziawg-go, sets up routes/iptables and DNS via
  # android.net.IDnsResolver over Binder (dlopen libbinder_ndk.so at
  # runtime, so no explicit link against libbinder is needed).
  "$CC" -O2 -D_GNU_SOURCE \
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
    # Take the module path from go.mod dynamically (at the time of writing it
    # is github.com/amnezia-vpn/amneziawg-go/v3), so this doesn't break if the
    # upstream major version changes.
    GOMOD_PATH="$(head -1 go.mod | awk '{print $2}')"
    go build -trimpath \
      -ldflags="-s -w -X ${GOMOD_PATH}/ipc.socketDirectory=${GO_SOCKET_DIR}" \
      -o "$OUT_DIR/amneziawg-go" .
  )

  echo "==> awg, awg-quick, amneziawg-go for $ARCH are ready in $OUT_DIR"
done

echo "==> [6/6] Copying awg-supervisor (single POSIX sh, no compilation) and packaging zip"
for ARCH in $ARCHES; do
  cp "$MODULE_DIR/bin/awg-supervisor" "$MODULE_DIR/bin/arch/$ARCH/awg-supervisor"
  chmod +x "$MODULE_DIR/bin/arch/$ARCH/"*
done

bash "$SCRIPT_DIR/package.sh"

echo "==> Done. See the resulting zip in build/dist/"
