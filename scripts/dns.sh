#!/system/bin/sh
# dns.sh up|down
# Android has no resolvconf/systemd-resolved, so DNS for the VPN interface
# is set via `ndc resolver` (Netd Control) - the same mechanism used
# internally by Android's own WireGuard VpnService-based clients.
#
# NOTE: awg-quick (wg-quick/android.c) already configures DNS on its own
# via android.net.IDnsResolver over Binder. This script is an OPTIONAL
# fallback/extra hook, only invoked when AWG_EXTRA_HOOKS=1 is set - useful
# mainly on firmwares where libbinder_ndk.so isn't available.

IFACE="${AWG_IFACE:-wg0}"
MODDIR="${AWG_MODDIR:-$(dirname "$0")/..}"
LOG="$MODDIR/logs/dns.log"
DNS_BACKUP="$MODDIR/logs/.dns_backup"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Read DNS servers from the config ("DNS = ..." line in [Interface])
read_dns_from_config() {
  CONFIG="$1"
  grep -E '^[[:space:]]*DNS[[:space:]]*=' "$CONFIG" 2>/dev/null \
    | head -n1 | cut -d'=' -f2 | tr -d ' ' | tr ',' ' '
}

up() {
  CONFIG="$1"
  DNS_SERVERS="$(read_dns_from_config "$CONFIG")"
  if [ -z "$DNS_SERVERS" ]; then
    log "No DNS set in the config, skipping"
    return 0
  fi
  log "dns up: iface=$IFACE dns=$DNS_SERVERS"

  # Back up the current default DNS so it can be restored on down
  getprop net.dns1 > "$DNS_BACKUP" 2>/dev/null

  if command -v ndc >/dev/null 2>&1; then
    ndc resolver setnetdns "$IFACE" "" $DNS_SERVERS 2>>"$LOG"
  else
    log "ndc not available, DNS was not applied (needs root/ndc in PATH)"
  fi
}

down() {
  log "dns down: iface=$IFACE"
  if command -v ndc >/dev/null 2>&1; then
    ndc resolver clearnetdns "$IFACE" 2>>"$LOG"
  fi
  rm -f "$DNS_BACKUP"
}

case "$1" in
  up) up "$2" ;;
  down) down ;;
  *) echo "usage: dns.sh {up <config>|down}"; exit 1 ;;
esac
