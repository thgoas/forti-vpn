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

# Consecutive failed ping checks tolerated before tearing the tunnel down. A
# single blip (or a PING_TARGET that momentarily doesn't answer) should not
# trigger a reconnect; the SA going down still reconnects immediately.
HEALTH_FAIL_LIMIT="${HEALTH_FAIL_LIMIT:-3}"

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
# virtual IP — the container's own eth0 address is not tunnelled. We assign it to
# a local interface (see setup_vip_iface) so it is a usable source and so
# decapsulated replies to it are delivered; PREV_VIP tracks the last one to
# remove on reconnect (the FortiGate may hand out a different IP each time).
VIRTUAL_IP=""
PREV_VIP=""

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

# Assign the mode-config virtual IP to the container's primary interface as a
# /32. strongSwan does not reliably install it inside a container, and without a
# local copy of the address (a) `ping -I <vip>` fails to bind ("Cannot assign
# requested address") so the watchdog can never verify the tunnel, and (b)
# decapsulated replies destined to the virtual IP are dropped. The peer SNAT path
# does not need this, but the watchdog does.
setup_vip_iface() {
  [ -n "$VIRTUAL_IP" ] || return 0
  local dev
  dev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  dev="${dev:-eth0}"

  if [ -n "$PREV_VIP" ] && [ "$PREV_VIP" != "$VIRTUAL_IP" ]; then
    ip addr del "${PREV_VIP}/32" dev "$dev" 2>/dev/null
  fi
  ip addr replace "${VIRTUAL_IP}/32" dev "$dev"
  PREV_VIP="$VIRTUAL_IP"
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
      setup_vip_iface
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

# Stop strongSwan from overwriting /etc/resolv.conf with the tunnel's internal
# DNS servers. Those cannot resolve the public gateway hostnames, so after the
# first connect a reconnect/failover to another gateway fails with "unable to
# resolve <gateway>". The container resolves gateways via Docker's DNS and
# reaches internal hosts by IP, so it never needs the internal resolvers.
mkdir -p /etc/strongswan.d/charon
printf 'resolve {\n    load = no\n}\n' > /etc/strongswan.d/charon/resolve.conf

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
# Authoritative health signal is the IPsec SA state. strongSwan's own DPD
# (dpdaction=restart) already tears down and reconnects a dead gateway, so the
# watchdog only reconnects when the SA has been down for HEALTH_FAIL_LIMIT
# consecutive checks (a backstop for cases DPD misses). The PING_TARGET check is
# ADVISORY by default: a ping failure is logged but does NOT reconnect, because
# sourcing a ping from the virtual IP is fragile (interface/route/RPF details)
# and a false negative there used to flap a perfectly healthy tunnel. Set
# WATCHDOG_PING_RECONNECT=true to restore ping-triggered reconnects.
WATCHDOG_PING_RECONNECT="${WATCHDOG_PING_RECONNECT:-false}"
log "Watchdog started (interval=${PING_INTERVAL}s, target=${PING_TARGET}, fail_limit=${HEALTH_FAIL_LIMIT}, ping_reconnect=${WATCHDOG_PING_RECONNECT})"
fails=0
while true; do
  sleep "$PING_INTERVAL"

  if ! is_tunnel_up; then
    fails=$((fails + 1))
    log "Health check: IPsec SA is down (${fails}/${HEALTH_FAIL_LIMIT})"
  else
    [ "$fails" -ne 0 ] && log "Health check recovered after ${fails} failure(s)"
    fails=0
    # Advisory route check — logs a broken route to PING_TARGET without tearing
    # the tunnel down, unless explicitly opted in.
    if [ -n "$PING_TARGET" ] \
       && ! ping -c 2 -W 3 ${VIRTUAL_IP:+-I "$VIRTUAL_IP"} "$PING_TARGET" >/dev/null 2>&1; then
      if [ "$WATCHDOG_PING_RECONNECT" = "true" ]; then
        fails="$HEALTH_FAIL_LIMIT"
        log "Health check FAILED: ping to ${PING_TARGET} failed, reconnecting (opt-in)"
      else
        log "WARNING: ping to ${PING_TARGET} failed but SA is up — not reconnecting"
      fi
    fi
  fi

  if [ "$fails" -ge "$HEALTH_FAIL_LIMIT" ]; then
    log "Tunnel down on ${HOSTS[$ACTIVE]}, reconnecting"
    stop_vpn
    log "Waiting ${RECONNECT_WAIT}s before reconnect"
    sleep "$RECONNECT_WAIT"

    # connect() retries the current gateway first, then fails over to the other.
    if connect; then
      log "Tunnel restored"
    else
      log "WARNING: no gateway came up, will retry next cycle"
    fi
    fails=0
  fi
done
