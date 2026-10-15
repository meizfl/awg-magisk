#!/system/bin/sh
# Magisk Action entry point. The supervisor serializes toggle decisions and
# transitions under one lock, so status and start/stop cannot race each other.

MODDIR=${0%/*}
LOG="$MODDIR/logs/action.log"
export PATH="$MODDIR/bin:/system/bin:/system/xbin:$PATH"
export WG_QUICK_USERSPACE_IMPLEMENTATION="$MODDIR/bin/amneziawg-go"
export AWG_MODDIR="$MODDIR"
export CALLING_PACKAGE="org.amnezia.awg"

CONFIG="$MODDIR/config/wg0.conf"
mkdir -p "$MODDIR/logs" "$MODDIR/run"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] action.sh triggered" >> "$LOG"

OUT="$MODDIR/run/action.$$.log"
if "$MODDIR/bin/awg-supervisor" toggle "$CONFIG" > "$OUT" 2>&1; then
  cat "$OUT"
  cat "$OUT" >> "$LOG"
  rm -f "$OUT"
else
  RC=$?
  cat "$OUT"
  cat "$OUT" >> "$LOG"
  echo "ERROR: Action failed (exit $RC). See $LOG"
  rm -f "$OUT"
  exit "$RC"
fi
