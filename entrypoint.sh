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
VPN_TRUSTED_CERT="${VPN_TRUSTED_CERT:-}"

# Optional secondary gateway for failover. Port/cert fall back to the primary's
# values when their *2 counterparts are empty.
VPN_HOST2="${VPN_HOST2:-}"
VPN_PORT2="${VPN_PORT2:-$VPN_PORT}"
VPN_TRUSTED_CERT2="${VPN_TRUSTED_CERT2:-}"

# Same credentials are used for both gateways.
VPN_USER="${VPN_USER:-}"
VPN_PASS="${VPN_PASS:-}"

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

# --- Gateway list (primary first, secondary appended when configured) -------
HOSTS=("$VPN_HOST")
PORTS=("$VPN_PORT")
CERTS=("$VPN_TRUSTED_CERT")

if [ -n "$VPN_HOST2" ]; then
  HOSTS+=("$VPN_HOST2")
  PORTS+=("$VPN_PORT2")
  CERTS+=("$VPN_TRUSTED_CERT2")
fi

NUM_HOSTS=${#HOSTS[@]}
ACTIVE=0
VPN_PID=""

# --- Functions --------------------------------------------------------------
start_vpn() {
  local host="${HOSTS[$ACTIVE]}"
  local port="${PORTS[$ACTIVE]}"
  local cert="${CERTS[$ACTIVE]}"

  log "Starting openfortivpn against ${host}:${port} as ${VPN_USER}"

  set -- "${host}:${port}" \
    --username="${VPN_USER}" \
    --password="${VPN_PASS}"

  if [ -n "$cert" ]; then
    set -- "$@" --trusted-cert "${cert}"
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

switch_host() {
  ACTIVE=$(( (ACTIVE + 1) % NUM_HOSTS ))
}

# Try to bring the tunnel up, failing over across all configured gateways.
# Starts from the currently active host and rotates through the rest.
connect() {
  local tries=0
  while [ "$tries" -lt "$NUM_HOSTS" ]; do
    start_vpn
    if wait_for_tunnel; then
      log "Tunnel is up on ${HOSTS[$ACTIVE]} (ppp0)"
      return 0
    fi

    log "Gateway ${HOSTS[$ACTIVE]} did not come up within 20s"
    stop_vpn
    tries=$((tries + 1))

    if [ "$NUM_HOSTS" -gt 1 ] && [ "$tries" -lt "$NUM_HOSTS" ]; then
      switch_host
      log "Failing over to ${HOSTS[$ACTIVE]}"
      sleep "$RECONNECT_WAIT"
    fi
  done
  return 1
}

# Clean shutdown on container stop
trap 'log "Received termination signal, shutting down"; stop_vpn; exit 0' TERM INT

# --- Initial connection -----------------------------------------------------
if [ "$NUM_HOSTS" -gt 1 ]; then
  log "Configured gateways: ${HOSTS[*]} (failover enabled)"
else
  log "Configured gateway: ${HOSTS[0]}"
fi

if ! connect; then
  log "ERROR: no gateway came up (tried: ${HOSTS[*]})"
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
    log "Tunnel unhealthy on ${HOSTS[$ACTIVE]}, reconnecting"
    stop_vpn
    log "Waiting ${RECONNECT_WAIT}s before reconnect"
    sleep "$RECONNECT_WAIT"

    # connect() retries the current gateway first, then fails over to the other.
    if connect; then
      log "Tunnel restored"
    else
      log "WARNING: no gateway came up, will retry next cycle"
    fi
  fi
done
