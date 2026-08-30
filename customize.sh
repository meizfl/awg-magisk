#!/system/bin/sh
# customize.sh - executed by the Magisk app when the module is installed

SKIPUNZIP=0

ui_print "- AmneziaWG (awg-quick) Magisk Module"
ui_print "- Detecting device architecture..."

# $API - device SDK level, exported by Magisk into customize.sh's
# environment automatically (equivalent to Build.VERSION.SDK_INT).
if [ -n "${API:-}" ]; then
  ui_print "- Device Android API level: $API"
  if [ "$API" -lt 21 ]; then
    ui_print "! Android API $API is below 21 (Lollipop) - binaries are built"
    ui_print "! with NDK r23+, which cannot target devices this old."
    abort "! Installation is not possible on this Android version"
  elif [ "$API" -lt 24 ]; then
    ui_print "- Android $API (< 7.0 Nougat, ABI<24 target): the interface"
    ui_print "  and routing will work as expected. DNS via"
    ui_print "  android.net.IDnsResolver (Binder) may be unavailable on some"
    ui_print "  such firmwares - awg-quick then silently skips that step"
    ui_print "  (see binder_available in the source), routing and iptables"
    ui_print "  rules are unaffected. If DNS breaks, enable the fallback in"
    ui_print "  scripts/dns.sh (AWG_EXTRA_HOOKS=1)."
  fi
fi

case "$ARCH" in
  arm64) BIN_ARCH="arm64" ;;
  arm)   BIN_ARCH="arm" ;;
  x64)   BIN_ARCH="x86_64" ;;
  x86)   BIN_ARCH="x86" ;;
  *) ui_print "! Unknown architecture: $ARCH"; abort "! Installation aborted" ;;
esac

ui_print "- Architecture: $BIN_ARCH"

# If binaries in the archive are laid out under arch/<arch>/ subfolders,
# move the matching set into bin/ and drop the rest to keep the module lean.
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
