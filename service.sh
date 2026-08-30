#!/system/bin/sh
# service.sh - запускается Magisk в контексте late_start service (после boot)
# Поднимает AmneziaWG интерфейс через awg-supervisor.

MODDIR=${0%/*}
LOG="$MODDIR/logs/service.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

mkdir -p "$MODDIR/logs"
: > "$LOG"
log "service.sh started, MODDIR=$MODDIR"

# UAPI-сокет amneziawg-go/awg живёт в run/ (см. build/build.sh) - / и /var
# на Android read-only, поэтому дефолтный /var/run недоступен.
mkdir -p "$MODDIR/run"

# Ждём полной загрузки системы
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 1
done
log "boot_completed=1"

# Небольшая пауза, чтобы сеть успела подняться
sleep 5

export PATH="$MODDIR/bin:/system/bin:/system/xbin:$PATH"
export WG_QUICK_USERSPACE_IMPLEMENTATION="$MODDIR/bin/amneziawg-go"
export AWG_MODDIR="$MODDIR"
export CALLING_PACKAGE="org.amnezia.awg"

CONFIG="$MODDIR/config/wg0.conf"

if [ ! -f "$CONFIG" ]; then
  log "ERROR: конфиг $CONFIG не найден, выход"
  exit 1
fi

# Разрешаем чтение конфига только root
chmod 600 "$CONFIG" 2>/dev/null

log "Запуск awg-supervisor start"
"$MODDIR/bin/awg-supervisor" start "$CONFIG" >> "$LOG" 2>&1 &

log "service.sh завершил инициализацию (supervisor работает в фоне)"
