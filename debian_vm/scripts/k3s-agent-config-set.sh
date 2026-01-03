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
# get ipv6 prefix from IP assuming /64
IPV6PREFIX=$(echo $IP | cut -d: -f1-4)
# alternative: get ipv6 prefix via router advertisement
IPV6PREFIXFULL=$(rdisc6 -q $INTERFACE)

echo "$(hostname) details: IPv6 address=$IP, DOMAIN=$DOMAIN, IPV6PREFIX=$IPV6PREFIX , IPV6PREFIXFULL=$IPV6PREFIXFULL"

mkdir -p /etc/rancher/k3s
cat >/etc/rancher/k3s/config.yaml <<EOL
node-ip: $IP
flannel-backend: none
disable-network-policy: true
disable:
  - traefik
EOL


echo "Final k3s config."
cat /etc/rancher/k3s/config.yaml
