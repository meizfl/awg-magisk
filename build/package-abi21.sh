#!/usr/bin/env bash
# package.sh - packages the finished module (after build.sh) into awg-quick-magisk.zip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
ZIP_NAME="awg-quick-magisk-abi21+.zip"

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$ZIP_NAME"

if [ ! -d "$MODULE_DIR/bin/arch" ] || [ -z "$(ls -A "$MODULE_DIR/bin/arch" 2>/dev/null)" ]; then
  echo "ERROR: bin/arch is empty. Run build.sh first to build the binaries." >&2
  exit 1
fi

cd "$MODULE_DIR"
zip -r -X "$DIST_DIR/$ZIP_NAME" \
  module.prop customize.sh service.sh action.sh uninstall.sh \
  bin/arch config scripts logs README.md META-INF \
  -x "*.DS_Store" -x "build/*"

echo "Built: $DIST_DIR/$ZIP_NAME"
