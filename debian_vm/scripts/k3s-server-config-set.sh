#!/bin/bash

# --- Find the primary IPv6 interface (the one with a global route) ---
INTERFACE=$(ip -6 route show default | awk '{print $7; exit}')

if [ -z "$INTERFACE" ]; then
    echo "Error: No default IPv6 route found"
    exit 1
fi

# --- Get the stable global IPv6 address (non-temporary, scope global) ---
# On Linux, temporary/privacy addresses have the "temporary" flag or are marked deprecated
IP=$(ip -6 addr show dev "$INTERFACE" scope global \
     | awk '/inet6/ {print $2}' \
     | cut -d/ -f1 \
     | grep -v '^fd' \
     | grep -v '^fe80' \
     | grep -v 'temporary' \
     | head -1)

if [ -z "$IP" ]; then
    echo "Error: No stable global IPv6 address found on $INTERFACE"
    exit 1
fi


DOMAIN=k8s.lzadm.com

# Get first 3 hextets of IPv6 prefix (e.g., 2001:a61:1162)
# This is the /48 portion that's stable across your /56 delegation
IPV6PREFIX_48=$(echo $IP | cut -d: -f1-3)

# Subnet allocation from Fritzbox /56 via /63 delegation to pfSense:
#   79fc::/64 = Host network (nodes get addresses via RA)
#   79fd::/64 = k3s cluster-cidr (pods)
# Service CIDR and DNS are within the cluster-cidr /64
CLUSTER_SUBNET="79fd"

# alternative: get ipv6 prefix via router advertisement
IPV6PREFIXFULL=$(rdisc6 -q $INTERFACE)

echo "$(hostname) details:"
echo "  Node IPv6 address: $IP"
echo "  Cluster domain: $DOMAIN"
echo "  Prefix /48: $IPV6PREFIX_48"
echo "  Cluster CIDR: ${IPV6PREFIX_48}:${CLUSTER_SUBNET}::/64"
echo "  RA prefix: $IPV6PREFIXFULL"

mkdir -p /etc/rancher/k3s
cat >/etc/rancher/k3s/config.yaml <<EOL
node-ip: $IP
cluster-domain: $DOMAIN
cluster-cidr: '${IPV6PREFIX_48}:${CLUSTER_SUBNET}::/64'
service-cidr: '${IPV6PREFIX_48}:${CLUSTER_SUBNET}:ff00::/112'
cluster-dns: '${IPV6PREFIX_48}:${CLUSTER_SUBNET}:ff00::10'
flannel-backend: none
disable-network-policy: true
tls-san:
  - "ctrl.$DOMAIN"
disable:
  - traefik
EOL

echo ""
echo "Final k3s config:"
cat /etc/rancher/k3s/config.yaml
