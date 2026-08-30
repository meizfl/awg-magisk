#!/system/bin/sh
# network.sh - вспомогательные функции, используемые awg-supervisor.
# Не запускается напрямую как daemon, а сорсится ( . network.sh ) другими скриптами.

IFACE="${AWG_IFACE:-wg0}"

# Ждём наличия рабочего сетевого подключения (Wi-Fi/мобильные данные)
wait_for_network() {
  TRIES=0
  MAX_TRIES="${1:-30}"
  while [ "$TRIES" -lt "$MAX_TRIES" ]; do
    if getprop net.dns1 2>/dev/null | grep -q '[0-9]'; then
      return 0
    fi
    # Альтернативная проверка: есть ли дефолтный маршрут
    if ip route get 8.8.8.8 >/dev/null 2>&1; then
      return 0
    fi
    TRIES=$((TRIES + 1))
    sleep 2
  done
  return 1
}

# Проверяет, что интерфейс awg0 поднят и имеет адрес
iface_is_up() {
  ip link show "$IFACE" >/dev/null 2>&1
}

# Определяет разумный MTU для туннеля в зависимости от текущего аплинка
detect_mtu() {
  UPLINK_MTU="$(ip link show dev "$(ip route show default | awk '{print $5; exit}')" 2>/dev/null \
    | grep -oE 'mtu [0-9]+' | awk '{print $2}')"
  if [ -n "$UPLINK_MTU" ]; then
    echo $((UPLINK_MTU - 80))
  else
    echo 1380
  fi
}
