#!/system/bin/sh
# customize.sh - run by Magisk Manager/App during module installation

SKIPUNZIP=0

ui_print "- AmneziaWG (awg-quick) Magisk Module"
ui_print "- Detecting device architecture..."

case "$ARCH" in
  arm64) BIN_ARCH="arm64" ;;
  arm)   BIN_ARCH="arm" ;;
  x64)   BIN_ARCH="x86_64" ;;
  x86)   BIN_ARCH="x86" ;;
  *) ui_print "! Unknown architecture: $ARCH"; abort "! Installation aborted" ;;
esac

ui_print "- Architecture: $BIN_ARCH"

# If the archive has binaries laid out under arch/<arch>/ subfolders,
# move the ones we need into bin/ and remove the rest to avoid bloating the module.
if [ -d "$MODPATH/bin/arch" ]; then
  if [ -d "$MODPATH/bin/arch/$BIN_ARCH" ]; then
    cp -f "$MODPATH/bin/arch/$BIN_ARCH/"* "$MODPATH/bin/" 2>/dev/null
  else
    ui_print "! No binaries found for $BIN_ARCH in the archive"
    abort "! Rebuild the module for this architecture (build/build.sh)"
  fi
  rm -rf "$MODPATH/bin/arch"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/awg" 0 0 0755
set_perm "$MODPATH/bin/awg-quick" 0 0 0755
set_perm "$MODPATH/bin/amneziawg-go" 0 0 0755
set_perm "$MODPATH/bin/awg-supervisor" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
mkdir -p "$MODPATH/logs"
set_perm_recursive "$MODPATH/logs" 0 0 0755 0644
mkdir -p "$MODPATH/run"
set_perm_recursive "$MODPATH/run" 0 0 0755 0755

ui_print "- Don't forget to edit config/wg0.conf before starting!"
ui_print "- Done."
