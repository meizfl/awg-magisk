#!/usr/bin/env bash
# build.sh — кросс-компилирует awg, awg-quick и amneziawg-go под Android
# (bionic libc) и раскладывает результат по bin/arch/<arch>/ модуля,
# затем упаковывает финальный Magisk-flashable zip.
#
# Требования на машине сборки:
#   - bash, curl или wget, unzip, git
#   - Go >= 1.21 (для сборки amneziawg-go)
#   - доступ в интернет к github.com и dl.google.com (для Android NDK)
#
# Использование:
#   ./build.sh              # соберёт под все ABI: arm64, arm, x86_64, x86
#   ./build.sh arm64         # только под arm64-v8a (самый частый случай)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$SCRIPT_DIR/.work"
NDK_VERSION="r27c"
NDK_ZIP="android-ndk-${NDK_VERSION}-linux.zip"
NDK_URL="https://dl.google.com/android/repository/${NDK_ZIP}"
API_LEVEL=24   # Android 7.0+, разумный минимум для современных VPN-клиентов

AWG_TOOLS_REPO="https://github.com/amnezia-vpn/amneziawg-tools.git"
AWG_GO_REPO="https://github.com/amnezia-vpn/amneziawg-go.git"

ARCHES="${1:-arm64 arm x86_64 x86}"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "==> [1/5] Подготовка Android NDK ${NDK_VERSION}"
if [ ! -d "$WORK_DIR/android-ndk-${NDK_VERSION}" ]; then
  if [ ! -f "$NDK_ZIP" ]; then
    curl -fL -o "$NDK_ZIP" "$NDK_URL"
  fi
  unzip -q "$NDK_ZIP"
fi
NDK_HOME="$WORK_DIR/android-ndk-${NDK_VERSION}"
TOOLCHAIN="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"

echo "==> [2/5] Клонирование исходников amneziawg-tools и amneziawg-go"
[ -d amneziawg-tools ] || git clone --depth 1 "$AWG_TOOLS_REPO" amneziawg-tools
[ -d amneziawg-go ]    || git clone --depth 1 "$AWG_GO_REPO" amneziawg-go

# Карта: наше имя ABI -> (Go GOARCH, clang target triple, каталог в bin/arch)
declare -A GOARCH_MAP=( [arm64]=arm64 [arm]=arm [x86_64]=amd64 [x86]=386 )
declare -A CLANG_TARGET=(
  [arm64]="aarch64-linux-android${API_LEVEL}"
  [arm]="armv7a-linux-androideabi${API_LEVEL}"
  [x86_64]="x86_64-linux-android${API_LEVEL}"
  [x86]="i686-linux-android${API_LEVEL}"
)

# Куда android.c ищет конфиги по умолчанию - совпадает с id модуля в module.prop
MODULE_ID="awg_quick_magisk"
MODDIR_ON_DEVICE="/data/adb/modules/${MODULE_ID}"
CONFIG_SEARCH_PATH="${MODDIR_ON_DEVICE}/config"

# На Android "/" и "/var" смонтированы read-only, поэтому дефолтный путь
# UAPI-сокета /var/run/amneziawg/<iface>.sock ломается с "read-only file
# system". Переносим сокет в каталог модуля (он на /data, всегда writable).
# Это ОБЩИЙ контракт между C-утилитой awg (макрос RUNSTATEDIR, задаётся
# через `make RUNSTATEDIR=...`) и Go-демоном amneziawg-go (переменная
# ipc.socketDirectory, задаётся через `-ldflags -X`, специально
# экспортирована для этого в исходниках amneziawg-go). Оба должны совпасть,
# иначе `awg` не сможет подключиться к сокету демона.
RUNSTATEDIR="${MODDIR_ON_DEVICE}/run"                 # для C: SOCK_PATH = RUNSTATEDIR "/amneziawg/"
GO_SOCKET_DIR="${RUNSTATEDIR}/amneziawg"               # для Go: sockPath = socketDirectory + "/" + iface + ".sock"

for ARCH in $ARCHES; do
  echo "==> [3/6] Сборка awg (CLI, цель Makefile называется 'wg') для $ARCH"
  CC="$TOOLCHAIN/bin/${CLANG_TARGET[$ARCH]}-clang"
  STRIP="$TOOLCHAIN/bin/llvm-strip"
  OUT_DIR="$MODULE_DIR/bin/arch/$ARCH"
  mkdir -p "$OUT_DIR"

  ( cd amneziawg-tools/src
    make clean >/dev/null 2>&1 || true
    # Реальная цель в Makefile называется "wg" (переименовывается в awg
    # только на этапе `make install`). Bionic на устройстве уже есть -
    # статическая линковка не нужна и часто ломается на NDK, поэтому
    # собираем как обычный динамический ELF под Android ABI.
    # RUNSTATEDIR переопределяет путь UAPI-сокета (см. комментарий выше).
    CC="$CC" CFLAGS="-O2" make RUNSTATEDIR="$RUNSTATEDIR" wg -j"$(nproc)"
    "$STRIP" wg -o "$OUT_DIR/awg"
  )

  echo "==> [4/6] Компиляция нативного awg-quick (wg-quick/android.c) для $ARCH"
  # У amneziawg-tools/wireguard-tools ЕСТЬ готовая C-реализация wg-quick
  # специально под Android (wg-quick/android.c): она сама поднимает
  # интерфейс через amneziawg-go, настраивает маршруты/iptables и DNS
  # через android.net.IDnsResolver по Binder (dlopen libbinder_ndk.so
  # в рантайме, поэтому явная линковка с libbinder_ndk не нужна).
  "$CC" -O2 -D_GNU_SOURCE \
    -DAWG_CONFIG_SEARCH_PATHS="\"${CONFIG_SEARCH_PATH}\"" \
    "amneziawg-tools/src/wg-quick/android.c" \
    -o "$OUT_DIR/awg-quick" -ldl
  "$STRIP" "$OUT_DIR/awg-quick"

  echo "==> [5/6] Сборка amneziawg-go для $ARCH (GOOS=android, cgo)"
  (
    cd amneziawg-go
    export GOOS=android
    export GOARCH="${GOARCH_MAP[$ARCH]}"
    export CGO_ENABLED=1
    export CC="$TOOLCHAIN/bin/${CLANG_TARGET[$ARCH]}-clang"
    export CXX="$TOOLCHAIN/bin/${CLANG_TARGET[$ARCH]}-clang++"
    # Путь модуля берём из go.mod динамически (на момент написания это
    # github.com/amnezia-vpn/amneziawg-go/v3), чтобы не сломаться при
    # смене мажорной версии апстрима.
    GOMOD_PATH="$(head -1 go.mod | awk '{print $2}')"
    go build -trimpath \
      -ldflags="-s -w -X ${GOMOD_PATH}/ipc.socketDirectory=${GO_SOCKET_DIR}" \
      -o "$OUT_DIR/amneziawg-go" .
  )

  echo "==> awg, awg-quick, amneziawg-go для $ARCH готовы в $OUT_DIR"
done

echo "==> [6/6] Копирование awg-supervisor (единый POSIX sh, без компиляции) и упаковка zip"
for ARCH in $ARCHES; do
  cp "$MODULE_DIR/bin/awg-supervisor" "$MODULE_DIR/bin/arch/$ARCH/awg-supervisor"
  chmod +x "$MODULE_DIR/bin/arch/$ARCH/"*
done

bash "$SCRIPT_DIR/package.sh"

echo "==> Готово. Смотрите итоговый zip в build/dist/"
