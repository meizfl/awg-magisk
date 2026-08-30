#!/system/bin/sh
# uninstall.sh - выполняется Magisk перед окончательным удалением модуля.
# Гарантированно опускает интерфейс и чистит маршруты/DNS, чтобы не оставить
# устройство без сети.

MODDIR=${0%/*}
export PATH="$MODDIR/bin:/system/bin:/system/xbin:$PATH"
export WG_QUICK_USERSPACE_IMPLEMENTATION="$MODDIR/bin/amneziawg-go"
export AWG_MODDIR="$MODDIR"
export CALLING_PACKAGE="org.amnezia.awg"

CONFIG="$MODDIR/config/wg0.conf"

if [ -x "$MODDIR/bin/awg-supervisor" ]; then
  "$MODDIR/bin/awg-supervisor" stop "$CONFIG" >/dev/null 2>&1
fi

# На всякий случай убиваем процессы напрямую, если supervisor недоступен
pkill -f "amneziawg-go" 2>/dev/null
pkill -f "awg-supervisor" 2>/dev/null

# Откат правил маршрутизации/DNS, если скрипты доступны
[ -x "$MODDIR/scripts/routing.sh" ] && "$MODDIR/scripts/routing.sh" down >/dev/null 2>&1
[ -x "$MODDIR/scripts/dns.sh" ] && "$MODDIR/scripts/dns.sh" down >/dev/null 2>&1

exit 0
