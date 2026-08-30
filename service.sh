#!/system/bin/sh
# service.sh - run by Magisk in the late_start service context (after boot)
# Brings up the AmneziaWG interface via awg-supervisor.

MODDIR=${0%/*}
LOG="$MODDIR/logs/service.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

mkdir -p "$MODDIR/logs"
: > "$LOG"
log "service.sh started, MODDIR=$MODDIR"

# The amneziawg-go/awg UAPI socket lives under run/ (see build/build.sh) - / and
# /var are read-only on Android, so the default /var/run is not writable.
mkdir -p "$MODDIR/run"

# Wait for the system to finish booting
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 1
done
log "boot_completed=1"

# Small delay to let the network come up
sleep 5

export PATH="$MODDIR/bin:/system/bin:/system/xbin:$PATH"
export WG_QUICK_USERSPACE_IMPLEMENTATION="$MODDIR/bin/amneziawg-go"
export AWG_MODDIR="$MODDIR"
export CALLING_PACKAGE="org.amnezia.awg"

CONFIG="$MODDIR/config/wg0.conf"

if [ ! -f "$CONFIG" ]; then
  log "ERROR: config $CONFIG not found, exiting"
  exit 1
fi

# Restrict config readability to root only
chmod 600 "$CONFIG" 2>/dev/null

log "Starting awg-supervisor start"
"$MODDIR/bin/awg-supervisor" start "$CONFIG" >> "$LOG" 2>&1 &

log "service.sh finished initialization (supervisor running in background)"
