#!/system/bin/sh
# action.sh - вызывается при нажатии кнопки "Action" в Magisk App.
# Переключает (toggle) состояние интерфейса awg0: up <-> down.

MODDIR=${0%/*}
LOG="$MODDIR/logs/action.log"
export PATH="$MODDIR/bin:/system/bin:/system/xbin:$PATH"
export WG_QUICK_USERSPACE_IMPLEMENTATION="$MODDIR/bin/amneziawg-go"
export AWG_MODDIR="$MODDIR"
export CALLING_PACKAGE="org.amnezia.awg"

CONFIG="$MODDIR/config/wg0.conf"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] action.sh triggered" >> "$LOG"

if "$MODDIR/bin/awg-supervisor" status >/dev/null 2>&1; then
  echo "AmneziaWG активен, останавливаю..."
  "$MODDIR/bin/awg-supervisor" stop "$CONFIG" >> "$LOG" 2>&1
  echo "Остановлено."
else
  echo "AmneziaWG выключен, запускаю..."
  "$MODDIR/bin/awg-supervisor" start "$CONFIG" >> "$LOG" 2>&1
  echo "Запущено."
fi
