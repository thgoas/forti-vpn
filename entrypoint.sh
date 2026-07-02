#!/bin/bash
set -u

log() {
  echo "[$(date '+%F %T')] $*"
}

# --- /dev/ppp ---------------------------------------------------------------
# openfortivpn needs /dev/ppp; create it if the container doesn't provide it.
if [ ! -e /dev/ppp ]; then
  log "Creating /dev/ppp (c 108 0)"
  mknod /dev/ppp c 108 0
fi

# --- Environment variables --------------------------------------------------
VPN_HOST="${VPN_HOST:-}"
VPN_PORT="${VPN_PORT:-443}"
VPN_USER="${VPN_USER:-}"
VPN_PASS="${VPN_PASS:-}"
VPN_TRUSTED_CERT="${VPN_TRUSTED_CERT:-}"
PING_TARGET="${PING_TARGET:-}"
PING_INTERVAL="${PING_INTERVAL:-30}"
RECONNECT_WAIT="${RECONNECT_WAIT:-5}"

if [ -z "$VPN_HOST" ] || [ -z "$VPN_USER" ] || [ -z "$VPN_PASS" ]; then
  log "ERROR: VPN_HOST, VPN_USER and VPN_PASS are required"
  exit 1
fi

if [ -z "$PING_TARGET" ]; then
  log "ERROR: PING_TARGET is required for the watchdog"
  exit 1
fi

VPN_PID=""

# --- Functions --------------------------------------------------------------
start_vpn() {
  log "Starting openfortivpn against ${VPN_HOST}:${VPN_PORT} as ${VPN_USER}"

  set -- "${VPN_HOST}:${VPN_PORT}" \
    --username="${VPN_USER}" \
    --password="${VPN_PASS}"

  if [ -n "$VPN_TRUSTED_CERT" ]; then
    set -- "$@" --trusted-cert "${VPN_TRUSTED_CERT}"
  fi

  openfortivpn "$@" &
  VPN_PID=$!
  log "openfortivpn started (PID ${VPN_PID})"
}

is_tunnel_up() {
  ip link show ppp0 >/dev/null 2>&1
}

wait_for_tunnel() {
  local waited=0
  while [ "$waited" -lt 20 ]; do
    if is_tunnel_up; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

stop_vpn() {
  if [ -n "$VPN_PID" ] && kill -0 "$VPN_PID" 2>/dev/null; then
    log "Killing VPN process (PID ${VPN_PID})"
    kill "$VPN_PID" 2>/dev/null
    wait "$VPN_PID" 2>/dev/null
  fi
  VPN_PID=""
}

# Clean shutdown on container stop
trap 'log "Received termination signal, shutting down"; stop_vpn; exit 0' TERM INT

# --- Initial connection -----------------------------------------------------
start_vpn

if wait_for_tunnel; then
  log "Tunnel is up (ppp0)"
else
  log "ERROR: tunnel did not come up within 20s"
  stop_vpn
  exit 1
fi

# --- Watchdog loop ----------------------------------------------------------
log "Watchdog started (interval=${PING_INTERVAL}s, target=${PING_TARGET})"
while true; do
  sleep "$PING_INTERVAL"

  healthy=true

  if ! is_tunnel_up; then
    log "Health check FAILED: interface ppp0 is gone"
    healthy=false
  elif ! ping -c 2 -W 3 "$PING_TARGET" >/dev/null 2>&1; then
    log "Health check FAILED: ping to ${PING_TARGET} failed"
    healthy=false
  fi

  if [ "$healthy" = false ]; then
    log "Tunnel unhealthy, reconnecting"
    stop_vpn
    log "Waiting ${RECONNECT_WAIT}s before reconnect"
    sleep "$RECONNECT_WAIT"
    start_vpn

    if wait_for_tunnel; then
      log "Tunnel is back up (ppp0)"
    else
      log "WARNING: tunnel did not come back up within 20s, will retry next cycle"
    fi
  fi
done
