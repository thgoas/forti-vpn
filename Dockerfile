FROM debian:bookworm-slim

# openfortivpn lives in Debian stable; iproute2 provides `ip` (used by the
# watchdog), iputils-ping provides `ping`, ca-certificates for TLS validation.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openfortivpn \
        iproute2 \
        iputils-ping \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
