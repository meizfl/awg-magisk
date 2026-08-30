#!/system/bin/sh
# uninstall.sh - run by Magisk before the module is finally removed.
# Guarantees the interface is brought down and routes/DNS are cleaned up, so
# the device isn't left without network.

MODDIR=${0%/*}
export PATH="$MODDIR/bin:/system/bin:/system/xbin:$PATH"
export WG_QUICK_USERSPACE_IMPLEMENTATION="$MODDIR/bin/amneziawg-go"
export AWG_MODDIR="$MODDIR"
export CALLING_PACKAGE="org.amnezia.awg"

CONFIG="$MODDIR/config/wg0.conf"

if [ -x "$MODDIR/bin/awg-supervisor" ]; then
  "$MODDIR/bin/awg-supervisor" stop "$CONFIG" >/dev/null 2>&1
fi

# Just in case, kill the processes directly if the supervisor is unavailable
pkill -f "amneziawg-go" 2>/dev/null
pkill -f "awg-supervisor" 2>/dev/null

# Roll back routing/DNS rules if the scripts are available
[ -x "$MODDIR/scripts/routing.sh" ] && "$MODDIR/scripts/routing.sh" down >/dev/null 2>&1
[ -x "$MODDIR/scripts/dns.sh" ] && "$MODDIR/scripts/dns.sh" down >/dev/null 2>&1

exit 0
