#!/bin/bash

# =============================================================================
# k3s Agent Configuration Script (ULA-based for ISP prefix resilience)
# =============================================================================
#
# This script configures k3s agent nodes to use ULA (Unique Local Addresses)
# for cluster communication, making them resilient to ISP IPv6 prefix changes.
#
# The agent only needs to know its node IP - cluster/service CIDRs are
# configured on the server nodes.
#
# =============================================================================

# Fixed ULA prefix - never changes regardless of ISP
ULA_PREFIX="fd77:3be9:5d2e"

# --- Find the primary IPv6 interface (the one with a global route) ---
INTERFACE=$(ip -6 route show default | awk '{print $7; exit}')

if [ -z "$INTERFACE" ]; then
    echo "Error: No default IPv6 route found"
    exit 1
fi

# --- Get the node's ULA address (from SLAAC, advertised by pfSense) ---
# ULA addresses start with fd or fc
NODE_IP=$(ip -6 addr show dev "$INTERFACE" scope global \
     | awk '/inet6/ {print $2}' \
     | cut -d/ -f1 \
     | grep "^${ULA_PREFIX}" \
     | head -1)

if [ -z "$NODE_IP" ]; then
    echo "Error: No ULA address found on $INTERFACE matching prefix ${ULA_PREFIX}"
    echo "Make sure pfSense is advertising the ULA prefix via Router Advertisements"
    echo ""
    echo "Available IPv6 addresses on $INTERFACE:"
    ip -6 addr show dev "$INTERFACE" scope global | grep inet6
    exit 1
fi

# Also get the GUA address for reference
GUA_IP=$(ip -6 addr show dev "$INTERFACE" scope global \
     | awk '/inet6/ {print $2}' \
     | cut -d/ -f1 \
     | grep -v '^fd' \
     | grep -v '^fc' \
     | grep -v '^fe80' \
     | grep -v 'temporary' \
     | head -1)

DOMAIN=k8s.lzadm.com

echo "$(hostname) k3s agent configuration:"
echo ""
echo "  Node IP (ULA):  $NODE_IP"
echo "  Node IP (GUA):  ${GUA_IP:-'Not available'}"
echo "  Cluster domain: $DOMAIN"

mkdir -p /etc/rancher/k3s
cat >/etc/rancher/k3s/config.yaml <<EOL
# k3s agent configuration using ULA for cluster communication
# This makes the agent resilient to ISP IPv6 prefix changes
node-ip: $NODE_IP
flannel-backend: none
disable-network-policy: true
disable:
  - traefik
EOL

echo ""
echo "Generated /etc/rancher/k3s/config.yaml:"
cat /etc/rancher/k3s/config.yaml

echo ""
echo "Next steps:"
echo "  Join cluster: curl -sfL https://get.k3s.io | K3S_TOKEN=<token> sh -s - agent --server https://k8s-node01:6443"
