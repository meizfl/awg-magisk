#!/system/bin/sh
# uninstall.sh - executed by Magisk right before the module is removed for
# good. Reliably tears down the interface and cleans up routes/DNS so the
# device isn't left without networking.

MODDIR=${0%/*}
export PATH="$MODDIR/bin:/system/bin:/system/xbin:$PATH"
export WG_QUICK_USERSPACE_IMPLEMENTATION="$MODDIR/bin/amneziawg-go"
export AWG_MODDIR="$MODDIR"
export CALLING_PACKAGE="org.amnezia.awg"

CONFIG="$MODDIR/config/wg0.conf"

if [ -x "$MODDIR/bin/awg-supervisor" ]; then
  "$MODDIR/bin/awg-supervisor" stop "$CONFIG" >/dev/null 2>&1
fi

# Kill the processes directly too, just in case awg-supervisor is unavailable
pkill -f "amneziawg-go" 2>/dev/null
pkill -f "awg-supervisor" 2>/dev/null

# Roll back routing/DNS rules if the optional hook scripts are present
[ -x "$MODDIR/scripts/routing.sh" ] && "$MODDIR/scripts/routing.sh" down >/dev/null 2>&1
[ -x "$MODDIR/scripts/dns.sh" ] && "$MODDIR/scripts/dns.sh" down >/dev/null 2>&1

exit 0
