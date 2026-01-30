#!/bin/bash

# --- Find the primary IPv6 interface (the one with a global route) ---
INTERFACE=$(ip -6 route show default | awk '{print $7; exit}')

if [ -z "$INTERFACE" ]; then
    echo "Error: No default IPv6 route found"
    exit 1
fi

# --- Get the ULA IPv6 address (stable across ISP prefix changes) ---
# ULA addresses (fd00::/8 and fc00::/8 per RFC 4193) remain stable when ISP prefix changes
IP=$(ip -6 addr show dev "$INTERFACE" scope global \
     | awk '/inet6/ {print $2}' \
     | cut -d/ -f1 \
     | grep -E '^fd|^fc' \
     | head -1)

if [ -z "$IP" ]; then
    echo "Error: No ULA IPv6 address found on $INTERFACE"
    exit 1
fi

# --- Get search/domain from systemd-resolved ---
# Modern Ubuntu uses systemd-resolved; search domains are in /etc/resolv.conf (symlink)
DOMAIN=$(grep '^search' /etc/resolv.conf | awk '{print $2}' | head -1)

if [ -z "$DOMAIN" ]; then
    # Alternative: query systemd-resolved directly
    DOMAIN=$(resolvectl status | grep 'DNS Domain' | awk '{print $3}' | head -1)
fi

if [ -z "$DOMAIN" ]; then
    echo "Warning: No search domain found; using fallback"
    DOMAIN="home.lzadm.com"
fi

# --- Get hostname and clean it for DNS ---
# Use system's hostname, remove invalid DNS characters
COMPUTER_NAME=$(hostname)

# Optional: use short hostname only (without domain if present)
# COMPUTER_NAME=$(hostname -s)

CLEAN_NAME=$(echo "$COMPUTER_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/-/g' | sed 's/^-*//;s/-*$//')
HOST="${CLEAN_NAME}.${DOMAIN}"

# --- Get the primary IPv6 DNS server ---
SERVER=$(resolvectl status | grep 'DNS Servers' | grep ':' | awk '{print $3}' | head -1)

if [ -z "$SERVER" ]; then
    # Fallback: ask systemd-resolved
    SERVER=$(resolvectl status | grep 'DNS Servers' | grep ':' | awk '{print $3}' | head -1)
fi

if [ -z "$SERVER" ]; then
    echo "Error: No IPv6 DNS server found"
    exit 1
fi

# --- Configuration ---
BIND9_PORT=5353
# KEYFILE="/path/to/tsig.key"  # Uncomment and set if using TSIG

echo "Updating $HOST with $IP (interface: $INTERFACE) via DNS server $SERVER:$BIND9_PORT"

# --- Build nsupdate command ---
NSUPDATE_CMD="nsupdate -d -p $BIND9_PORT"

# If using TSIG key, uncomment:
# NSUPDATE_CMD="$NSUPDATE_CMD -k $KEYFILE"

$NSUPDATE_CMD << EOF
server $SERVER
zone $DOMAIN
update delete $HOST AAAA
update add $HOST 300 AAAA $IP
send
EOF

echo "Update sent."
