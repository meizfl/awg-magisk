#!/system/bin/sh
# action.sh - invoked when the "Action" button is pressed in the Magisk App.
# Toggles the awg0 interface state: up <-> down.

MODDIR=${0%/*}
LOG="$MODDIR/logs/action.log"
export PATH="$MODDIR/bin:/system/bin:/system/xbin:$PATH"
export WG_QUICK_USERSPACE_IMPLEMENTATION="$MODDIR/bin/amneziawg-go"
export AWG_MODDIR="$MODDIR"
export CALLING_PACKAGE="org.amnezia.awg"

CONFIG="$MODDIR/config/wg0.conf"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] action.sh triggered" >> "$LOG"

if "$MODDIR/bin/awg-supervisor" status >/dev/null 2>&1; then
  echo "AmneziaWG is active, stopping..."
  "$MODDIR/bin/awg-supervisor" stop "$CONFIG" >> "$LOG" 2>&1
  echo "Stopped."
else
  echo "AmneziaWG is down, starting..."
  "$MODDIR/bin/awg-supervisor" start "$CONFIG" >> "$LOG" 2>&1
  echo "Started."
fi
