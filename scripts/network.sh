#!/system/bin/sh
# network.sh - helper functions used by awg-supervisor.
# Not run directly as a daemon; sourced ( . network.sh ) by other scripts.

IFACE="${AWG_IFACE:-wg0}"

# Wait for a working network connection (Wi-Fi/mobile data)
wait_for_network() {
  TRIES=0
  MAX_TRIES="${1:-30}"
  while [ "$TRIES" -lt "$MAX_TRIES" ]; do
    if getprop net.dns1 2>/dev/null | grep -q '[0-9]'; then
      return 0
    fi
    # Alternative check: is there a default route
    if ip route get 8.8.8.8 >/dev/null 2>&1; then
      return 0
    fi
    TRIES=$((TRIES + 1))
    sleep 2
  done
  return 1
}

# Checks that the interface is up and present
iface_is_up() {
  ip link show "$IFACE" >/dev/null 2>&1
}

# Picks a reasonable MTU based on the current uplink
detect_mtu() {
  UPLINK_MTU="$(ip link show dev "$(ip route show default | awk '{print $5; exit}')" 2>/dev/null \
    | grep -oE 'mtu [0-9]+' | awk '{print $2}')"
  if [ -n "$UPLINK_MTU" ]; then
    echo $((UPLINK_MTU - 80))
  else
    echo 1380
  fi
}
