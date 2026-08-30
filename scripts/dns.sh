#!/system/bin/sh
# dns.sh up|down
# Android has no resolvconf/systemd-resolved, so DNS for the VPN interface
# is set via `ndc resolver` (Netd Control) - the same mechanism used by
# the built-in Android VpnService for WireGuard clients.

IFACE="${AWG_IFACE:-wg0}"
MODDIR="${AWG_MODDIR:-$(dirname "$0")/..}"
LOG="$MODDIR/logs/dns.log"
DNS_BACKUP="$MODDIR/logs/.dns_backup"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Read DNS servers from the config (the "DNS = ..." line in [Interface])
read_dns_from_config() {
  CONFIG="$1"
  grep -E '^[[:space:]]*DNS[[:space:]]*=' "$CONFIG" 2>/dev/null \
    | head -n1 | cut -d'=' -f2 | tr -d ' ' | tr ',' ' '
}

up() {
  CONFIG="$1"
  DNS_SERVERS="$(read_dns_from_config "$CONFIG")"
  if [ -z "$DNS_SERVERS" ]; then
    log "DNS not set in config, skipping"
    return 0
  fi
  log "dns up: iface=$IFACE dns=$DNS_SERVERS"

  # Save the current default network DNS to restore it on down
  getprop net.dns1 > "$DNS_BACKUP" 2>/dev/null

  if command -v ndc >/dev/null 2>&1; then
    ndc resolver setnetdns "$IFACE" "" $DNS_SERVERS 2>>"$LOG"
  else
    log "ndc not available, DNS not applied (root/ndc in PATH required)"
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
