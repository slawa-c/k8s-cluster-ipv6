# Kubernetes cluster in home lab with IPv6 only setup

> **Note:** See [CLAUDE.md](CLAUDE.md) for comprehensive documentation including network topology, BGP configuration, and troubleshooting.

## Description

The main idea is to deploy kubernetes cluster in my home lab in subnet where only IPv6 network available, for sure I configured my pfsense router with DNS64 and NAT64 features to provide communications from ipv6 only enabled hosts to ipv4 only resources in Internet.

## Network Topology

```
[ISP DSLite /56: 2001:a61:1162::/56]
              │
              ▼
        [Fritzbox] ── DHCPv6-PD ──┬──▶ [Mikrotik hex-s]  79e0::/60 (79e0-79ef)
                                  ├──▶ [Unifi UDR7]      79fa::/64
                                  └──▶ [pfSense]         79fb::/64
                                                           ├── 79fb:0000-ffcb:: → host/node network (RA)
                                                           ├── 79fb:ffcc::/112 → k3s pods (BGP, filtered)
                                                           ├── 79fb:ff00::/112 → k3s services (BGP)
                                                           └── 79fb:ff01::/112 → LoadBalancer IPs (BGP)
```

**BGP AS Numbers:**
| Device | AS Number |
|--------|-----------|
| pfSense (FRR) | 65101 |
| k3s/Calico | 65010 |

## Host system

I try to spinup all these VMs on my macbook M2max using VMware Fusion, since I have it. I prepared parent VM based on Linux Debian 13, and spin up several linced clone VMs.

### Basic Debian configuration

### debian 13

```bash
apt -y install nano vim net-tools dnsutils iputils-ping traceroute tcpdump iptables sipcalc ndisc6 curl wget apt-transport-https
```

### basic network setup - move to systemd-networkd

<https://wiki.debian.org/SystemdNetworkd>

```bash
root@debian:~# mv /etc/network/interfaces /etc/network/interfaces.save
root@debian:~# mv /etc/network/interfaces.d /etc/network/interfaces.d.save
root@debian:~# systemctl enable systemd-networkd
root@debian:~# systemctl status systemd-networkd
```

#### create systemd network config

```bash
cat <<EOF > /etc/systemd/network/10-enp2s0.network
[Match]
Name=enp2s0

[Network]
DHCP=no
IPv6AcceptRA=yes
LinkLocalAddressing=ipv6

[IPv6AcceptRA]
UseDNS=yes
UseDomains=yes

[DHCP]
RouteMetric=100
UseMTU=true

[DHCPv6]
UseDNS=yes
UseDomains=yes
UseAddress=yes
EOF

systemctl restart systemd-networkd
```

### install DNS resolver

```bash
sudo apt install systemd-resolved
```

### Update and clean parent VM

Before generalizing, ensure the VM is up-to-date and remove unnecessary data to minimize the template size.

```bash
apt update && apt full-upgrade -y
apt autoremove -y && apt clean
```

This removes unused packages and clears the APT cache.
Optionally, clear logs and temporary files:
text

```bash
journalctl --vacuum-time=1d  # If using systemd-journald
rm -rf /var/log/* /tmp/* /var/tmp/*
```

### Make sysctl changes

```bash
echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.accept_ra = 2" >> /etc/sysctl.conf
sysctl -p

net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
```

### Generalize script example

There is a need to make basic config for parent VM and generalize snapshot of this VM to use it as linked clones, the generalize-script.sh can be like this:

```bash
#!/bin/bash
set -e

# Run as root
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo rm -f /etc/ssh/ssh_host_*
sudo rm -f /etc/udev/rules.d/70-persistent-net.rules
sudo rm -f /var/lib/dhcp/*.leases
sudo journalctl --vacuum-time=1s
sudo apt clean
sudo rm -rf /tmp/* /var/tmp/*
truncate -s 0 ~/.bash_history
history -c

echo "VM generalized. Shut down now and convert to template."
```

### nsupdate script for updating DNS names in home lab DNS zone

Save script content below to nsupdate-script-pfsense.sh and put file in root home directory on debian parent VM.

```bash
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
```

### run generalize-script.sh and shutdown parent VM

```bash
chmod +x generalise-script.sh
./generalise-script.sh
shutdown -h now
```

## Prepare k8s-node01 VM for kubernetes

### change hostname

```bash
hostnamectl set-hostname k8s-node1
```

### Generate ssh host keys

```bash
/usr/bin/ssh-keygen -A
systemctl restart ssh
```

### Disable swap for better performance

```bash
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

### add admin user

```bash
adduser admin
usermod -aG sudo admin
```

### make sysctl changes

```bash
echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.accept_ra = 2" >> /etc/sysctl.conf
sysctl -p
```

### check ipv6 prefix

```bash
rdisc6 -q enp2s0
```

### Run nsupdate script to create DNS nsme for the node

```bash
 ./nsupdate-pfsense-bind.sh
 ```

### docker apt repo

<https://docs.docker.com/engine/install/debian/>

#### Add Docker's official GPG key

```bash
apt update
apt install ca-certificates curl gpg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
```

#### Add the repository to Apt sources

```bash
tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
```

### containerd install

<https://kubernetes.io/docs/setup/production-environment/container-runtimes/#containerd-systemd>

```bash
apt install -y containerd.io
containerd config default | tee /etc/containerd/config.toml >/dev/null 2>&1
sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
```

to check containerd config:

```bash
containerd config dump | grep SystemdCgroup
            SystemdCgroup = true
```

restart containerd to apply new configuration

```bash
systemctl restart containerd
systemctl enable containerd
```

### k8s registry

<https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/>

#### Add Kubernetes repository

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
```

### Setup k3s

<https://renshaw.au/posts/the-cluster/>

#### k3s-server-config-set.sh

The script is located at `debian_vm/scripts/k3s-server-config-set.sh`. It automatically:
- Detects the node's IPv6 address and extracts the /48 prefix and 4th hextet
- Configures cluster-cidr using /112 within the host /64 (79fb:ffcc::/112)
- Sets up service CIDR and cluster DNS in separate /112 ranges
- Configures per-node allocation of /120 (256 pod IPs per node)

```bash
# Run the config script before installing k3s
./debian_vm/scripts/k3s-server-config-set.sh
```

The script generates `/etc/rancher/k3s/config.yaml` with:
- `cluster-cidr: <prefix>:<4th-hextet>:ffcc::/112`
- `service-cidr: <prefix>:<4th-hextet>:ff00::/112`
- `cluster-dns: <prefix>:<4th-hextet>:ff00::10`
- `node-cidr-mask-size-ipv6: 120` (256 pod IPs per node, max 256 nodes)

### install k3s

there is a need to create k3s config file before start k3s instalation script

```bash
./k3s-config-set.sh
```

#### on first k8s-node01

```bash
curl -sfL https://get.k3s.io | K3S_TOKEN=supersecret! sh -s - server --cluster-init
```

#### join k3s cluser on oter nodes

```bash
curl -sfL https://get.k3s.io | K3S_TOKEN=supersecret! sh -s - server --server https://k8s-node01:6443
```

```bash
### network CNI missing
kubectl get pods --all-namespaces -o wide
NAMESPACE     NAME                                      READY   STATUS              RESTARTS   AGE   IP       NODE         NOMINATED NODE   READINESS GATES
kube-system   coredns-7f496c8d7d-7kngk                  0/1     ContainerCreating   0          26s   <none>   k8s-node01   <none>           <none>
kube-system   local-path-provisioner-578895bd58-kdbmc   0/1     ContainerCreating   0          26s   <none>   k8s-node01   <none>           <none>
kube-system   metrics-server-7b9c9c4b9c-ghmbf           0/1     ContainerCreating   0          26s   <none>   k8s-node01   <none>           <none>
```

### install Calico CNI

<https://docs.tigera.io/calico/latest/getting-started/kubernetes/k3s/multi-node-install>

```bash
# Install Calico operator
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/operator-crds.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/tigera-operator.yaml

# Get the /48 prefix and 4th hextet from node IP
NODE_IP=$(ip -6 addr show scope global | awk '/inet6/ {print $2}' | cut -d/ -f1 | grep -v '^fd' | grep -v '^fe80' | head -1)
PREFIX_48=$(echo $NODE_IP | cut -d: -f1-3)
HEXTET_4=$(echo $NODE_IP | cut -d: -f4)

# Configure Calico with IPv6 using /112 cluster-cidr with /120 per-node blocks
kubectl create -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - blockSize: 120
        cidr: ${PREFIX_48}:${HEXTET_4}:ffcc::/112
        encapsulation: None
        natOutgoing: Enabled
        nodeSelector: all()
    nodeAddressAutodetectionV6:
      kubernetes: NodeInternalIP
EOF

# Create Calico API server
kubectl create -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
```

```bash
cat /etc/rancher/k3s/k3s.yaml
```

### Kubernetes API LoadBalancer (Recommended)

For reliable cluster management with automatic failover, expose the API via LoadBalancer:

```bash
# Convert kubernetes service to LoadBalancer
kubectl patch svc kubernetes -p '{"spec":{"type":"LoadBalancer","loadBalancerIP":"2001:a61:1162:79fb:ff01::1"}}'
kubectl annotate svc kubernetes external-dns.alpha.kubernetes.io/hostname=api.k8s.lzadm.com

# Update kubeconfig
kubectl config set-cluster default --server=https://api.k8s.lzadm.com:443
```

**Important:** Add auto-apply manifest on each server node to persist after restarts:
```bash
# On each k3s server node (k8s-node01, k8s-node02, k8s-node03)
sudo tee /var/lib/rancher/k3s/server/manifests/kubernetes-api-loadbalancer.yaml > /dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: kubernetes
  namespace: default
  annotations:
    external-dns.alpha.kubernetes.io/hostname: api.k8s.lzadm.com
  labels:
    component: apiserver
    provider: kubernetes
spec:
  type: LoadBalancer
  loadBalancerIP: 2001:a61:1162:79fb:ff01::1
  ports:
  - name: https
    port: 443
    protocol: TCP
    targetPort: 6443
  sessionAffinity: None
EOF
```

**Documentation:** See [k3s-api-loadbalancer.md](k3s-api-loadbalancer.md) for complete setup, TLS configuration, and troubleshooting.

### Alternative: Direct Node Access

Copy content k3s.yaml to ~/.kube/config for managing k3s cluster, replace

```bash
     server: https://k8s-node01:6443
```

### Calico BGP Configuration

See [CLAUDE.md](CLAUDE.md) for detailed BGP configuration with password authentication and [LoadBalance.md](LoadBalance.md) for MetalLB + Calico integration.

```bash
# Get the /48 prefix and 4th hextet
NODE_IP=$(ip -6 addr show scope global | awk '/inet6/ {print $2}' | cut -d/ -f1 | grep -v '^fd' | grep -v '^fe80' | head -1)
PREFIX_48=$(echo $NODE_IP | cut -d: -f1-3)
HEXTET_4=$(echo $NODE_IP | cut -d: -f4)

# 1. Configure Calico BGP with custom AS number (65010) and service advertisement
kubectl apply -f - <<EOF
apiVersion: projectcalico.org/v3
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: 65010
  serviceClusterIPs:
  - cidr: ${PREFIX_48}:${HEXTET_4}:ff00::/112
EOF

# 2. Create secret for BGP password
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bgp-secrets
  namespace: calico-system
type: Opaque
stringData:
  pfsense-password: "<your-bgp-password>"
EOF

# 3. Create RBAC for calico-node to read the secret
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: bgp-secret-access
  namespace: calico-system
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["bgp-secrets"]
  verbs: ["watch", "list", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bgp-secret-access
  namespace: calico-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: bgp-secret-access
subjects:
- kind: ServiceAccount
  name: calico-node
  namespace: calico-system
EOF

# 4. Create BGPFilter to control route advertisements (optional but recommended)
kubectl apply -f - <<EOF
apiVersion: projectcalico.org/v3
kind: BGPFilter
metadata:
  name: pfsense-export-filter
spec:
  exportV6:
    # Reject pod CIDR advertisements to pfSense (reduces routing table size)
    - action: Reject
      matchOperator: In
      cidr: ${PREFIX_48}:${HEXTET_4}:ffcc::/112
    # Default action is Accept - ClusterIP and LoadBalancer CIDRs pass through
EOF

# 5. Add pfSense as BGP peer with password authentication and filter
kubectl apply -f - <<EOF
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata:
  name: pfsense
spec:
  peerIP: <pfsense-ipv6-address>
  asNumber: 65101
  password:
    secretKeyRef:
      name: bgp-secrets
      key: pfsense-password
  # Apply filter to control route advertisements
  filters:
    - pfsense-export-filter
EOF
```

**BGPFilter Benefits:**
- Reduces pfSense routing table size by filtering pod routes
- Only advertises service CIDR (ff00::/112) and LoadBalancer IPs (ff01::/112)
- Pod routes (ffcc::/112) handled internally by Calico

### DNS Management with ExternalDNS

ExternalDNS automatically creates DNS records in pfSense BIND for LoadBalancer services, enabling home network devices to resolve cluster service names.

**Quick Setup:**

```bash
# 1. Generate TSIG key on pfSense
tsig-keygen -a hmac-sha256 externaldns-key

# 2. Configure BIND zone for dynamic updates
# See k3s-external-dns-pfsense.md for detailed instructions

# 3. Deploy ExternalDNS
kubectl apply -f external-dns-rfc2136.yaml

# 4. Add annotation to LoadBalancer services
kubectl annotate svc myapp external-dns.alpha.kubernetes.io/hostname=myapp.k8s.lzadm.com
```

**DNS Architecture:**
- **CoreDNS** (internal): Authoritative for cluster services (*.svc.k8s.lzadm.com)
- **BIND** (external): LoadBalancer service records managed by ExternalDNS
- Pods query CoreDNS → ClusterIP (internal, fast)
- Home network queries BIND → LoadBalancer IP (external access)

**Documentation:**
- Complete setup guide: [k3s-external-dns-pfsense.md](k3s-external-dns-pfsense.md)
- DNS architecture and best practices: [CLAUDE.md](CLAUDE.md#dns-management-with-externaldns)

### coredns check

```bash
# Example with prefix 2001:a61:1162:79fb - cluster DNS is at :ff00::10
nslookup metrics-server.kube-system.svc.k8s.lzadm.com 2001:a61:1162:79fb:ff00::10
Server:		2001:a61:1162:79fb:ff00::10
Address:	2001:a61:1162:79fb:ff00::10#53

Name:	metrics-server.kube-system.svc.k8s.lzadm.com
Address: 2001:a61:1162:79fb:ff00::xxxx
```

## External Access via Cloudflare Tunnels

Cloudflare Tunnels provide secure external access without public IPs or firewall configuration. Perfect for IPv6-only clusters.

See [CLAUDE.md](CLAUDE.md) for comprehensive documentation.

### Quick Setup

```bash
# 1. Install cloudflared CLI
sudo mkdir -p --mode=0755 /etc/apt/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /etc/apt/keyrings/cloudflare-public-v2.gpg >/dev/null
echo 'deb [signed-by=/etc/apt/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update && sudo apt-get install cloudflared

# 2. Authenticate and create tunnel
cloudflared tunnel login
cloudflared tunnel create k8s-lzadm-com-tunnel

# 3. Create Kubernetes secret
kubectl create secret generic tunnel-credentials \
  --from-file=credentials.json=/root/.cloudflared/<tunnel-id>.json

# 4. Deploy cloudflared to cluster
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cloudflared
spec:
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
      - name: cloudflared
        image: cloudflare/cloudflared:latest
        args:
        - tunnel
        - --edge-ip-version
        - "6"
        - --config
        - /etc/cloudflared/config/config.yaml
        - run
        livenessProbe:
          httpGet:
            path: /ready
            port: 2000
          failureThreshold: 1
          initialDelaySeconds: 10
          periodSeconds: 10
        volumeMounts:
        - name: config
          mountPath: /etc/cloudflared/config
          readOnly: true
        - name: creds
          mountPath: /etc/cloudflared/creds
          readOnly: true
      volumes:
      - name: creds
        secret:
          secretName: tunnel-credentials
      - name: config
        configMap:
          name: cloudflared
          items:
          - key: config.yaml
            path: config.yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared
data:
  config.yaml: |
    tunnel: k8s-lzadm-com-tunnel
    credentials-file: /etc/cloudflared/creds/credentials.json
    metrics: 0.0.0.0:2000
    no-autoupdate: true
    ingress:
    - hostname: "whoami.slawa.uk"
      service: http://whoami.default.svc.k8s.lzadm.com:80
    - service: http_status:404
EOF

# 5. Create DNS route
cloudflared tunnel route dns k8s-lzadm-com-tunnel "whoami.slawa.uk"
```

**Key Features:**
- IPv6 support via `--edge-ip-version: "6"`
- No public IP or firewall changes needed
- Free SSL/TLS certificates
- DDoS protection via Cloudflare

### uninstall k3s

```bash
/usr/local/bin/k3s-killall.sh
/usr/local/bin/k3s-uninstall.sh
logout
```
