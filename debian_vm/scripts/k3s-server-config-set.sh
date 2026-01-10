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

# Get 4th hextet from node IP (e.g., 79fb for host network)
# This identifies which /64 subnet the node is on
IPV6_4TH_HEXTET=$(echo $IP | cut -d: -f4)

# Subnet allocation from Fritzbox /56 via pfSense:
#   79fb::/64 = Host network (nodes get addresses via RA)
#   79fb:ffcc::/112 = k3s cluster-cidr (pods) - allows 256 /120 blocks
#   79fb:ff00::/112 = k3s service-cidr - 65,536 service IPs
# Using /112 cluster-cidr with /120 per-node allocation:
#   - Total pod IPs: 65,536 addresses
#   - Per node: /120 = 256 addresses
#   - Max nodes: 256 nodes
CLUSTER_POD_SUBNET="ffcc"
CLUSTER_SVC_SUBNET="ff00"

# alternative: get ipv6 prefix via router advertisement
IPV6PREFIXFULL=$(rdisc6 -q $INTERFACE)

echo "$(hostname) details:"
echo "  Node IPv6 address: $IP"
echo "  Cluster domain: $DOMAIN"
echo "  Prefix /48: $IPV6PREFIX_48"
echo "  Host network: ${IPV6PREFIX_48}:${IPV6_4TH_HEXTET}::/64"
echo "  Cluster CIDR: ${IPV6PREFIX_48}:${IPV6_4TH_HEXTET}:${CLUSTER_POD_SUBNET}::/112"
echo "  Service CIDR: ${IPV6PREFIX_48}:${IPV6_4TH_HEXTET}:${CLUSTER_SVC_SUBNET}::/112"
echo "  Per-node allocation: /120 (256 pod IPs per node, max 256 nodes)"
echo "  RA prefix: $IPV6PREFIXFULL"

mkdir -p /etc/rancher/k3s
cat >/etc/rancher/k3s/config.yaml <<EOL
node-ip: $IP
cluster-domain: $DOMAIN
cluster-cidr: '${IPV6PREFIX_48}:${IPV6_4TH_HEXTET}:${CLUSTER_POD_SUBNET}::/112'
service-cidr: '${IPV6PREFIX_48}:${IPV6_4TH_HEXTET}:${CLUSTER_SVC_SUBNET}::/112'
cluster-dns: '${IPV6PREFIX_48}:${IPV6_4TH_HEXTET}:${CLUSTER_SVC_SUBNET}::10'
flannel-backend: none
disable-network-policy: true
kube-controller-manager-arg:
  - node-cidr-mask-size-ipv6=120
tls-san:
  - "ctrl.$DOMAIN"
  - "k3s-cluster.$DOMAIN"
  - "api.$DOMAIN"
  - "${IPV6PREFIX_48}:${IPV6_4TH_HEXTET}:ff01::1"
disable:
  - traefik
EOL

echo ""
echo "Final k3s config:"
cat /etc/rancher/k3s/config.yaml
