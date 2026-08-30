#!/system/bin/sh
# service.sh - runs in Magisk's late_start service context (after boot).
# Brings up the AmneziaWG interface via awg-supervisor.

MODDIR=${0%/*}
LOG="$MODDIR/logs/service.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

mkdir -p "$MODDIR/logs"
: > "$LOG"
log "service.sh started, MODDIR=$MODDIR"

# The UAPI socket used by amneziawg-go/awg lives under run/ (see
# build/build.sh) - "/" and "/var" are read-only on Android, so the
# default /var/run path is unavailable.
mkdir -p "$MODDIR/run"

# Wait for the system to finish booting
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 1
done
log "boot_completed=1"

# Small delay so networking has time to come up
sleep 5

export PATH="$MODDIR/bin:/system/bin:/system/xbin:$PATH"
export WG_QUICK_USERSPACE_IMPLEMENTATION="$MODDIR/bin/amneziawg-go"
export AWG_MODDIR="$MODDIR"

# awg-quick (wg-quick/android.c) sends an `am broadcast` to the
# org.amnezia.awg app at the end of up/down to refresh its UI. We don't
# have that app installed - without this variable the broadcast targets a
# non-existent package, fails, and the whole `awg-quick up` gets rolled
# back (see broadcast_change() in wg-quick/android.c: if CALLING_PACKAGE
# matches AWG_PACKAGE_NAME, the broadcast is skipped entirely).
export CALLING_PACKAGE="org.amnezia.awg"

CONFIG="$MODDIR/config/wg0.conf"

if [ ! -f "$CONFIG" ]; then
  log "ERROR: config $CONFIG not found, exiting"
  exit 1
fi

# Only root should be able to read the config
chmod 600 "$CONFIG" 2>/dev/null

log "Starting awg-supervisor start"
"$MODDIR/bin/awg-supervisor" start "$CONFIG" >> "$LOG" 2>&1 &

log "service.sh finished initialization (supervisor running in background)"
