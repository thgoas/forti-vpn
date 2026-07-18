#!/bin/bash
set -u

log() {
  echo "[$(date '+%F %T')] $*"
}

CONN="fortigate"

# --- Environment variables --------------------------------------------------
VPN_HOST="${VPN_HOST:-}"
VPN_TRUSTED_CERT="${VPN_TRUSTED_CERT:-}"   # kept for compatibility, unused by IPsec

# Optional secondary gateway for failover (leave VPN_HOST2 empty to disable).
VPN_HOST2="${VPN_HOST2:-}"

# Credentials: PSK is the phase-1 pre-shared key, USER/PASS feed XAUTH.
VPN_PSK="${VPN_PSK:-}"
VPN_USER="${VPN_USER:-}"
VPN_PASS="${VPN_PASS:-}"

# Local/peer ID for the phase-1 negotiation. FortiGate dialup usually runs in
# aggressive mode keyed by a group/peer ID; set VPN_LOCAL_ID to that name and
# leave VPN_AGGRESSIVE=yes. For a plain IP-based main-mode dialup, leave
# VPN_LOCAL_ID empty and set VPN_AGGRESSIVE=no.
VPN_LOCAL_ID="${VPN_LOCAL_ID:-}"
VPN_AGGRESSIVE="${VPN_AGGRESSIVE:-yes}"

# Crypto proposals. These MUST match the FortiGate phase-1/phase-2 settings.
# DH group 14 = modp2048; the group on the ESP proposal is the PFS group.
VPN_IKE_PROPOSAL="${VPN_IKE_PROPOSAL:-aes256-sha256-modp2048,aes128-sha256-modp2048}"
VPN_ESP_PROPOSAL="${VPN_ESP_PROPOSAL:-aes256-sha256-modp2048,aes128-sha256-modp2048}"

# SA lifetimes, matched to the FortiGate phase-1/phase-2 key lifetimes.
VPN_IKE_LIFETIME="${VPN_IKE_LIFETIME:-86400s}"
VPN_KEY_LIFETIME="${VPN_KEY_LIFETIME:-43200s}"

# Remote subnets reachable through the tunnel (rightsubnet). Use 0.0.0.0/0 for a
# full tunnel, or a comma-separated list of the networks behind the FortiGate.
VPN_REMOTE_SUBNETS="${VPN_REMOTE_SUBNETS:-0.0.0.0/0}"

PING_TARGET="${PING_TARGET:-}"
PING_INTERVAL="${PING_INTERVAL:-30}"
RECONNECT_WAIT="${RECONNECT_WAIT:-5}"

# When true, act as a gateway: enable IPv4 forwarding and SNAT other containers'
# traffic to the tunnel's virtual IP so it matches the IPsec policy (policy-based
# IPsec only routes traffic sourced from the mode-config virtual IP). Peer
# containers must route the remote networks via this container's IP, e.g.:
#   ip route add 172.16.1.0/24 via 172.21.0.10
NAT_ENABLED="${NAT_ENABLED:-true}"
# Source subnet(s) whose forwarded traffic gets SNAT'd onto the tunnel.
VPN_PEER_SUBNET="${VPN_PEER_SUBNET:-172.21.0.0/16}"

if [ -z "$VPN_HOST" ] || [ -z "$VPN_USER" ] || [ -z "$VPN_PASS" ] || [ -z "$VPN_PSK" ]; then
  log "ERROR: VPN_HOST, VPN_USER, VPN_PASS and VPN_PSK are required"
  exit 1
fi

if [ -z "$PING_TARGET" ]; then
  log "ERROR: PING_TARGET is required for the watchdog"
  exit 1
fi

# --- Gateway list (primary first, secondary appended when configured) -------
HOSTS=("$VPN_HOST")
if [ -n "$VPN_HOST2" ]; then
  HOSTS+=("$VPN_HOST2")
fi
NUM_HOSTS=${#HOSTS[@]}
ACTIVE=0

# Mode-config virtual IP of the current tunnel. Locally-generated traffic (the
# watchdog ping) must be sourced from it, since the IPsec policy only covers the
# virtual IP — the container's own eth0 address is not tunnelled.
VIRTUAL_IP=""

# --- strongSwan configuration -----------------------------------------------
# ipsec.secrets holds the PSK and the XAUTH password; regenerated once (the
# credentials are the same for every gateway).
write_secrets() {
  umask 077
  {
    echo ": PSK \"${VPN_PSK}\""
    echo "${VPN_USER} : XAUTH \"${VPN_PASS}\""
  } > /etc/ipsec.secrets
}

# ipsec.conf is rewritten per gateway so `right` points at the active host; a
# reload picks up the change without restarting charon.
write_config() {
  local host="$1"
  local leftid_line=""
  [ -n "$VPN_LOCAL_ID" ] && leftid_line="    leftid=${VPN_LOCAL_ID}"

  cat > /etc/ipsec.conf <<EOF
config setup
    uniqueids=no

conn ${CONN}
    keyexchange=ikev1
    aggressive=${VPN_AGGRESSIVE}
    authby=xauthpsk
    xauth=client
    left=%defaultroute
${leftid_line}
    leftsourceip=%config
    right=${host}
    rightid=%any
    rightsubnet=${VPN_REMOTE_SUBNETS}
    ike=${VPN_IKE_PROPOSAL}!
    esp=${VPN_ESP_PROPOSAL}!
    ikelifetime=${VPN_IKE_LIFETIME}
    lifetime=${VPN_KEY_LIFETIME}
    xauth_identity=${VPN_USER}
    dpdaction=restart
    dpddelay=15s
    keyingtries=1
    auto=add
EOF
}

# --- Tunnel state -----------------------------------------------------------
is_tunnel_up() {
  ipsec status "$CONN" 2>/dev/null | grep -q INSTALLED
}

# The mode-config virtual IP is the local traffic selector of the child SA; SNAT
# targets it so forwarded traffic matches the IPsec policy.
get_virtual_ip() {
  ipsec statusall "$CONN" 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32 ===' \
    | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
    | head -n1
}

stop_vpn() {
  ipsec down "$CONN" >/dev/null 2>&1
}

# --- Gateway NAT ------------------------------------------------------------
# SNAT other containers' traffic to the tunnel's virtual IP (dynamic, so the
# rule is refreshed on every (re)connect). The old rule is removed first to stay
# idempotent across reconnects that change the virtual IP.
NAT_RULE_TAG="forti-vpn-snat"

clear_nat() {
  while iptables -t nat -S POSTROUTING 2>/dev/null | grep -q "$NAT_RULE_TAG"; do
    local spec
    spec=$(iptables -t nat -S POSTROUTING | grep "$NAT_RULE_TAG" | head -n1 | sed 's/^-A //')
    # shellcheck disable=SC2086
    iptables -t nat -D POSTROUTING $spec 2>/dev/null || break
  done
}

enable_nat() {
  [ "$NAT_ENABLED" = "true" ] || return 0

  if [ -z "$VIRTUAL_IP" ]; then
    log "WARNING: could not determine virtual IP, NAT not applied this cycle"
    return 0
  fi

  # Normally set by docker-compose's sysctls at start; only try to write it if
  # it isn't already on (avoids a noisy error on a read-only /proc/sys).
  if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 \
      || echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
  fi

  clear_nat
  iptables -t nat -A POSTROUTING -s "$VPN_PEER_SUBNET" \
    -m comment --comment "$NAT_RULE_TAG" -j SNAT --to-source "$VIRTUAL_IP"
  log "Gateway NAT enabled (ip_forward=1, SNAT ${VPN_PEER_SUBNET} -> ${VIRTUAL_IP})"
}

switch_host() {
  ACTIVE=$(( (ACTIVE + 1) % NUM_HOSTS ))
}

# Try to bring the tunnel up, failing over across all configured gateways.
connect() {
  local tries=0
  while [ "$tries" -lt "$NUM_HOSTS" ]; do
    local host="${HOSTS[$ACTIVE]}"
    log "Starting IPsec against ${host} as ${VPN_USER}"

    write_config "$host"
    ipsec reload >/dev/null 2>&1
    ipsec rereadsecrets >/dev/null 2>&1
    # Let charon finish (re)loading the connection before initiating; issuing
    # `ipsec up` too early races the config load and fails instantly.
    sleep 2

    # Foreground with a timeout: blocks until the SA is established or fails,
    # mirroring a manual `ipsec up`. A stuck negotiation is capped at 45s.
    timeout 45 ipsec up "$CONN" >/dev/null 2>&1

    if is_tunnel_up; then
      VIRTUAL_IP=$(get_virtual_ip)
      log "Tunnel is up on ${host} (IPsec SA INSTALLED, virtual IP ${VIRTUAL_IP:-unknown})"
      enable_nat
      return 0
    fi

    log "Gateway ${host} did not come up"
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
trap 'log "Received termination signal, shutting down"; clear_nat; ipsec stop >/dev/null 2>&1; exit 0' TERM INT

# --- Boot -------------------------------------------------------------------
write_secrets
write_config "${HOSTS[0]}"

log "Starting charon (strongSwan IKE daemon)"
ipsec start >/dev/null 2>&1
# Wait for the daemon's control socket before issuing commands.
waited=0
while [ "$waited" -lt 15 ]; do
  ipsec status >/dev/null 2>&1 && break
  sleep 1
  waited=$((waited + 1))
done

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

  # The ping must be sourced from the virtual IP, otherwise it leaves via eth0
  # unencrypted (outside the IPsec policy) and always fails.
  if ! is_tunnel_up; then
    log "Health check FAILED: IPsec SA is down"
    healthy=false
  elif ! ping -c 2 -W 3 ${VIRTUAL_IP:+-I "$VIRTUAL_IP"} "$PING_TARGET" >/dev/null 2>&1; then
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
