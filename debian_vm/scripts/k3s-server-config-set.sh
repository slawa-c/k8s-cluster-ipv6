#!/bin/bash

# =============================================================================
# k3s Server Configuration Script (ULA-based for ISP prefix resilience)
# =============================================================================
#
# This script configures k3s to use ULA (Unique Local Addresses) for internal
# cluster networking, making it resilient to ISP IPv6 prefix changes.
#
# Architecture:
#   - Node IPs: ULA from SLAAC (fd77:3be9:5d2e:1::/64)
#   - Cluster CIDR: ULA (fd77:3be9:5d2e:ffcc::/112)
#   - Service CIDR: ULA (fd77:3be9:5d2e:ff00::/112)
#   - LoadBalancer pool: GUA (configured separately in MetalLB)
#
# Benefits:
#   - ISP prefix changes only affect LoadBalancer IPs
#   - BGP peering remains stable (ULA addresses)
#   - No cluster restart needed for prefix changes
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

# Also get the GUA address for reference (used for LoadBalancer pool detection)
GUA_IP=$(ip -6 addr show dev "$INTERFACE" scope global \
     | awk '/inet6/ {print $2}' \
     | cut -d/ -f1 \
     | grep -v '^fd' \
     | grep -v '^fc' \
     | grep -v '^fe80' \
     | grep -v 'temporary' \
     | head -1)

DOMAIN=k8s.lzadm.com

# ULA subnet allocation:
#   fd77:3be9:5d2e:1::/64     = Node/infrastructure network (via RA from pfSense)
#   fd77:3be9:5d2e:ffcc::/112 = k3s cluster-cidr (pods) - 65,536 pod IPs
#   fd77:3be9:5d2e:ff00::/112 = k3s service-cidr (ClusterIP) - 65,536 service IPs
#
# Using /112 cluster-cidr with /120 per-node allocation:
#   - Total pod IPs: 65,536 addresses
#   - Per node: /120 = 256 addresses
#   - Max nodes: 256 nodes
CLUSTER_POD_SUBNET="ffcc"
CLUSTER_SVC_SUBNET="ff00"

# Get GUA prefix for LoadBalancer pool reference (first 4 hextets)
if [ -n "$GUA_IP" ]; then
    GUA_PREFIX=$(echo "$GUA_IP" | cut -d: -f1-4)
    LB_POOL_CIDR="${GUA_PREFIX}:ff01::/112"
else
    LB_POOL_CIDR="(GUA not available - configure manually)"
fi

echo "$(hostname) k3s server configuration:"
echo ""
echo "  ULA Configuration (stable - survives ISP prefix changes):"
echo "    Node IP (ULA):    $NODE_IP"
echo "    Cluster CIDR:     ${ULA_PREFIX}:${CLUSTER_POD_SUBNET}::/112"
echo "    Service CIDR:     ${ULA_PREFIX}:${CLUSTER_SVC_SUBNET}::/112"
echo "    Cluster DNS:      ${ULA_PREFIX}:${CLUSTER_SVC_SUBNET}::10"
echo ""
echo "  GUA Configuration (changes with ISP prefix):"
echo "    Node IP (GUA):    ${GUA_IP:-'Not available'}"
echo "    LoadBalancer pool: $LB_POOL_CIDR"
echo ""
echo "  Cluster domain:     $DOMAIN"
echo "  Per-node allocation: /120 (256 pod IPs per node, max 256 nodes)"

mkdir -p /etc/rancher/k3s
cat >/etc/rancher/k3s/config.yaml <<EOL
# k3s configuration using ULA for internal networking
# This makes the cluster resilient to ISP IPv6 prefix changes
node-ip: $NODE_IP
cluster-domain: $DOMAIN
cluster-cidr: '${ULA_PREFIX}:${CLUSTER_POD_SUBNET}::/112'
service-cidr: '${ULA_PREFIX}:${CLUSTER_SVC_SUBNET}::/112'
cluster-dns: '${ULA_PREFIX}:${CLUSTER_SVC_SUBNET}::10'
flannel-backend: none
disable-network-policy: true
kube-controller-manager-arg:
  - node-cidr-mask-size-ipv6=120
tls-san:
  - "ctrl.$DOMAIN"
  - "k3s-cluster.$DOMAIN"
  - "api.$DOMAIN"
  # ULA API LoadBalancer address
  - "${ULA_PREFIX}:ff01::1"
disable:
  - traefik
EOL

echo ""
echo "Generated /etc/rancher/k3s/config.yaml:"
cat /etc/rancher/k3s/config.yaml

echo ""
echo "Next steps:"
echo "  1. Install k3s: curl -sfL https://get.k3s.io | K3S_TOKEN=<token> sh -s - server --cluster-init"
echo "  2. Install Calico with ULA IPPool (see CLAUDE.md)"
echo "  3. Configure MetalLB with GUA LoadBalancer pool: $LB_POOL_CIDR"
