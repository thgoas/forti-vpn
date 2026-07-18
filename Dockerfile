FROM debian:bookworm-slim

# strongSwan is the standard Linux IPsec/IKE client and speaks FortiGate's
# dialup IPsec (IKEv1 + PSK + XAUTH). strongswan-starter provides the classic
# `ipsec` command + ipsec.conf/ipsec.secrets that the entrypoint templates.
# libcharon-extauth-plugins ships the xauth-generic plugin that answers
# FortiGate's XAUTH (username/password) challenge — without it charon reports
# "no XAuth method found" and the tunnel never completes. iproute2 provides
# `ip`, iputils-ping provides `ping` (watchdog), ca-certificates for TLS roots,
# iptables enables the SNAT that lets this container act as a gateway routing
# other containers over the tunnel.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        strongswan \
        strongswan-starter \
        libcharon-extauth-plugins \
        iproute2 \
        iputils-ping \
        ca-certificates \
        iptables \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
