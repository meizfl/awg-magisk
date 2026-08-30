#!/system/bin/sh
# dns.sh up|down
# На Android нет resolvconf/systemd-resolved, поэтому DNS для VPN-интерфейса
# выставляется через `ndc resolver` (Netd Control) — это тот же механизм,
# которым пользуется штатный VpnService у Android-клиентов WireGuard.

IFACE="${AWG_IFACE:-wg0}"
MODDIR="${AWG_MODDIR:-$(dirname "$0")/..}"
LOG="$MODDIR/logs/dns.log"
DNS_BACKUP="$MODDIR/logs/.dns_backup"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# DNS-сервера читаем из конфига (строка "DNS = ..." в [Interface])
read_dns_from_config() {
  CONFIG="$1"
  grep -E '^[[:space:]]*DNS[[:space:]]*=' "$CONFIG" 2>/dev/null \
    | head -n1 | cut -d'=' -f2 | tr -d ' ' | tr ',' ' '
}

up() {
  CONFIG="$1"
  DNS_SERVERS="$(read_dns_from_config "$CONFIG")"
  if [ -z "$DNS_SERVERS" ]; then
    log "DNS не задан в конфиге, пропускаю"
    return 0
  fi
  log "dns up: iface=$IFACE dns=$DNS_SERVERS"

  # Сохраняем текущие DNS сети по умолчанию, чтобы откатить при down
  getprop net.dns1 > "$DNS_BACKUP" 2>/dev/null

  if command -v ndc >/dev/null 2>&1; then
    ndc resolver setnetdns "$IFACE" "" $DNS_SERVERS 2>>"$LOG"
  else
    log "ndc недоступен, DNS не применён (нужен root/ndc в PATH)"
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
