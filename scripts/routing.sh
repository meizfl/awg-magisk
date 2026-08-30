#!/system/bin/sh
# routing.sh up|down
# Sets up policy routing for the AmneziaWG interface on Android.
# Uses /system/bin/ip (toybox/iproute2), available on rooted Android.

IFACE="${AWG_IFACE:-wg0}"
TABLE="${AWG_TABLE:-51820}"
FWMARK="${AWG_FWMARK:-51820}"
MODDIR="${AWG_MODDIR:-$(dirname "$0")/..}"
LOG="$MODDIR/logs/routing.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

up() {
  log "routing up: iface=$IFACE table=$TABLE fwmark=$FWMARK"

  # Main default route in a separate table, so we don't touch the systemwide default
  ip route add default dev "$IFACE" table "$TABLE" 2>>"$LOG"

  # Packets marked with fwmark go through our table (used by wg-quick
  # to avoid a routing loop for the VPN tunnel's own traffic)
  ip rule add not fwmark "$FWMARK" table "$TABLE" priority 51820 2>>"$LOG"
  ip rule add table main suppress_prefixlength 0 priority 51821 2>>"$LOG"

  # Allow local subnets (LAN) to bypass the VPN - a typical list of private ranges.
  # Edit as needed for your network.
  for net in 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12; do
    ip rule add to "$net" table main priority 51822 2>>"$LOG"
  done

  log "routing up: done"
}

down() {
  log "routing down: iface=$IFACE table=$TABLE"
  ip rule del priority 51820 2>>"$LOG"
  ip rule del priority 51821 2>>"$LOG"
  ip rule del priority 51822 2>>"$LOG"
  ip route flush table "$TABLE" 2>>"$LOG"
  log "routing down: done"
}

case "$1" in
  up) up ;;
  down) down ;;
  *) echo "usage: routing.sh {up|down}"; exit 1 ;;
esac
