# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

IPv6-only Kubernetes cluster home lab setup running k3s on Debian 13 VMs in VMware Fusion on macOS. The cluster uses DNS64/NAT64 on pfSense for IPv4 connectivity, Calico CNI for networking, and BGP peering with pfSense for service advertisement.

**Key Infrastructure:**
- **Network:** IPv6-only (2001:a61:1162:79fb::/64 single subnet with /112 ranges for k8s)
- **Router:** pfSense with DNS64/NAT64, FRR BGP (AS 65101)
- **Cluster:** k3s multi-node with Calico CNI, BGP peering (AS 65010)
- **DNS:** Cluster domain `k8s.lzadm.com`, home domain `home.lzadm.com`

**Network Topology:**
```
[ISP DSLite /56: 2001:a61:1162::/56]
              │
              ▼
        [Fritzbox] ── DHCPv6-PD ──┬──▶ [Mikrotik hex-s]  79e0::/60 (79e0-79ef)
                                  ├──▶ [Unifi UDR7]      79fa::/64
                                  └──▶ [pfSense]         79fb::/64
                                                           ├── 79fb:0000-ffcb:: → host/node network (RA)
                                                           ├── 79fb:ffcc::/112 → k3s pods (BGP)
                                                           └── 79fb:ff00::/112 → k3s services (BGP)
```

**Subnet Allocation from /56:**
| Prefix | Assignment | Notes |
|--------|------------|-------|
| 79e0::/60 | Mikrotik hex-s | 16 /64s (79e0-79ef) |
| 79fa::/64 | Unifi UDR7 | |
| 79fb::/64 | pfSense | Single /64 delegation |
| ├─ 79fb:0000-ffcb:: | pfSense LAN | Host/node network (RA advertised) |
| ├─ 79fb:ffcc::/112 | k3s cluster-cidr | Pod network (BGP advertised) |
| └─ 79fb:ff00::/112 | k3s service-cidr | Service network (BGP advertised) |
| 79fc-79ff | Available | Future use |

## Architecture

### VM Deployment Strategy
- **Parent VM:** Debian 13 template with systemd-networkd, generalized for cloning
- **Linked Clones:** VMs created from parent snapshot to save disk space
- **Node Types:**
  - Server nodes (control plane): use `k3s-server-config-set.sh`
  - Agent nodes (workers): use `k3s-agent-config-set.sh`

### IPv6 Network Configuration

**Single /64 Subnet Architecture:**
This setup uses a single /64 subnet from Fritzbox with /112 ranges for k8s:
- `2001:a61:1162:79fb::/64` - Full /64 allocation from pfSense
  - `79fb:0000-ffcb::` - Host/node network (advertised via RA)
  - `79fb:ffcc::/112` - Kubernetes pod network (routed via BGP)
  - `79fb:ff00::/112` - Kubernetes service network (routed via BGP)

**How it works:**
- pfSense receives single `/64` via DHCPv6-PD from Fritzbox
- pfSense advertises the full `/64` via Router Advertisements for host network
- Nodes receive SLAAC addresses from the lower portion of the /64
- k3s uses `79fb:ffcc::/112` for pods (learned via BGP from Calico)
- k3s uses `79fb:ff00::/112` for services (learned via BGP from Calico)
- BGP advertises only the /112 subnets to avoid routing conflicts

**Node network:**
- Nodes use systemd-networkd for IPv6 SLAAC (Stateless Address Autoconfiguration)
- Global IPv6 addresses obtained via router advertisements from pfSense
- No static IP assignment - addresses discovered dynamically
- DNS registration via `nsupdate-pfsense-bind.sh` to pfSense BIND9 (port 5353)

### k3s Cluster Architecture
- **Networking:** Calico CNI replaces built-in Flannel (disabled)
- **Service Advertisement:** Calico BGP peers with pfSense to advertise cluster services to home network
- **Load Balancing:** Traefik disabled (can be replaced with custom ingress)
- **Storage:** local-path-provisioner (built-in k3s)

### Critical Network Parameters (Auto-detected)

Scripts dynamically determine from the environment:
- IPv6 prefix (/48) extracted from node address: first 3 hextets (e.g., `2001:a61:1162`)
- 4th hextet extracted from node address (e.g., `79fb` for host network)
- Node network: `<prefix>:<4th-hextet>::/64` (auto-assigned via RA from pfSense)
- Cluster CIDR: `<prefix>:<4th-hextet>:ffcc::/112` (65,536 pod IPs)
- Service CIDR: `<prefix>:<4th-hextet>:ff00::/112` (65,536 service IPs)
- Cluster DNS: `<prefix>:<4th-hextet>:ff00::10`
- Node CIDR allocation: /120 per node (256 pod IPs per node)

**Example with current prefix:**
```
Node address:   2001:a61:1162:79fb:xxxx:xxxx:xxxx:xxxx
Cluster CIDR:   2001:a61:1162:79fb:ffcc::/112
Service CIDR:   2001:a61:1162:79fb:ff00::/112
Cluster DNS:    2001:a61:1162:79fb:ff00::10
Per-node CIDR:  /120 (256 pod IPs per node, supports 256 nodes)
```

**Important:** The script `k3s-server-config-set.sh` extracts the first 4 hextets from the node's IPv6 address to dynamically configure cluster networking. Using /112 for cluster-cidr with /120 per-node allocation provides a balanced approach: 65,536 total pod IPs with 256 IPs per node, supporting up to 256 nodes in the cluster.

## Prerequisites

### Parent VM Initial Setup

These steps must be completed on the Debian 13 parent VM before generalizing and creating the template.

**Install essential packages:**
```bash
apt -y install nano vim net-tools dnsutils iputils-ping traceroute tcpdump \
  iptables sipcalc ndisc6 curl wget apt-transport-https
```

**Configure systemd-networkd (IPv6 SLAAC):**
```bash
# Disable legacy networking
mv /etc/network/interfaces /etc/network/interfaces.save
mv /etc/network/interfaces.d /etc/network/interfaces.d.save

# Enable systemd-networkd
systemctl enable systemd-networkd

# Create network configuration (adjust interface name if needed)
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

**Install and enable DNS resolver:**
```bash
apt install systemd-resolved
systemctl enable systemd-resolved
```

**Configure sysctl for IPv6 forwarding:**
```bash
echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.accept_ra = 2" >> /etc/sysctl.conf
sysctl -p
```

**Add Docker repository (for containerd):**
```bash
apt update
apt install ca-certificates curl gpg
install -m 0755 -d /etc/apt/keyrings

# Add Docker GPG key
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add repository
tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
```

**Install and configure containerd:**
```bash
# Install
apt install -y containerd.io

# Configure with systemd cgroup driver
containerd config default | tee /etc/containerd/config.toml >/dev/null 2>&1
sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

# Verify configuration
containerd config dump | grep SystemdCgroup
# Should show: SystemdCgroup = true

# Enable and restart
systemctl enable containerd
systemctl restart containerd
```

**Add Kubernetes repository (optional - for kubeadm/kubectl if needed):**
```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | \
  tee /etc/apt/sources.list.d/kubernetes.list
```

**Update and clean before generalizing:**
```bash
apt update && apt full-upgrade -y
apt autoremove -y && apt clean
journalctl --vacuum-time=1d
rm -rf /var/log/* /tmp/* /var/tmp/*
```

**Copy scripts to parent VM:**
```bash
# Copy debian_vm/scripts/ directory to /root/ on the parent VM
# Ensure nsupdate-pfsense-bind.sh is in /root/ for DNS registration
```

### Network Infrastructure Requirements

**Fritzbox (upstream router):**
- DHCPv6 Prefix Delegation enabled
- Must delegate multiple prefixes to downstream routers
- Current delegations: /60 to Mikrotik, /64 to Unifi, /64 to pfSense

**pfSense router must have:**
- **DHCPv6-PD client** configured on WAN to request /64 from Fritzbox
- **Single /64 subnet** for both host network and cluster traffic:
  - 79fb::/64 for host network (advertised via RA)
  - 79fb:ffcc::/112 for k3s cluster-cidr (routed via BGP, NOT advertised via RA)
  - 79fb:ff00::/112 for k3s service-cidr
- IPv6 Router Advertisements enabled for host subnet
- DNS64/NAT64 configured for IPv4 reachability from IPv6-only hosts
- BIND9 running on port 5353 for dynamic DNS updates
- FRR package installed and configured for BGP (AS 65101)
- BGP peer group configured to accept connections from k8s nodes (AS 65010)
- **BGP learns routes** for cluster CIDR subnet (79fb:ffcc::/112) from Calico

**pfSense DHCPv6-PD Configuration:**
1. Interfaces → WAN → IPv6 Configuration Type: DHCPv6
2. DHCPv6 Client Configuration:
   - Prefix Delegation Size: /64
   - Send IPv6 prefix hint: Enabled
3. Interfaces → LAN → Track Interface → WAN with Prefix ID: 0
4. 79fb:ffcc::/112 is routed automatically via BGP from k3s/Calico nodes

**VMware Fusion configuration:**
- VMs must use bridged networking to access the IPv6 home network
- Network adapter should be connected to the same network as pfSense

## Common Commands

### VM Preparation

**Create parent VM template:**
```bash
# On parent VM after initial setup
cd debian_vm/scripts
./generalize_debian.sh
shutdown -h now
# Take snapshot in VMware Fusion
```

**Configure new node from linked clone:**
```bash
# Set hostname
hostnamectl set-hostname k8s-node01

# Generate SSH host keys
/usr/bin/ssh-keygen -A
systemctl restart ssh

# Register DNS name
./debian_vm/scripts/nsupdate-pfsense-bind.sh

# Disable swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

### k3s Cluster Operations

**Initialize first server node:**
```bash
./debian_vm/scripts/k3s-server-config-set.sh
curl -sfL https://get.k3s.io | K3S_TOKEN=supersecret! sh -s - server --cluster-init
```

**Join additional server nodes:**
```bash
./debian_vm/scripts/k3s-server-config-set.sh
curl -sfL https://get.k3s.io | K3S_TOKEN=supersecret! sh -s - server --server https://k8s-node01:6443
```

**Join agent nodes:**
```bash
./debian_vm/scripts/k3s-agent-config-set.sh
curl -sfL https://get.k3s.io | K3S_TOKEN=supersecret! sh -s - agent --server https://k8s-node01:6443
```

**Install Calico CNI:**
```bash
# Install operator
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
        natOutgoing: Disabled
        nodeSelector: all()
    nodeAddressAutodetectionV6:
      kubernetes: NodeInternalIP
EOF

# Create API server
kubectl create -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
```

**Configure BGP peering:**

BGP AS Numbers:
| Device | AS Number |
|--------|-----------|
| pfSense (FRR) | 65101 |
| k3s/Calico | 65010 |

```bash
# Get the /48 prefix and 4th hextet
NODE_IP=$(ip -6 addr show scope global | awk '/inet6/ {print $2}' | cut -d/ -f1 | grep -v '^fd' | grep -v '^fe80' | head -1)
PREFIX_48=$(echo $NODE_IP | cut -d: -f1-3)
HEXTET_4=$(echo $NODE_IP | cut -d: -f4)

# 1. Configure Calico BGP with custom AS number and service advertisement
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

# 2. Create secret for BGP password (must be in calico-system namespace)
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

# 3. Create RBAC to allow calico-node to read the secret
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

# 4. Add pfSense as BGP peer with password authentication
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
EOF
```

**Note:** BGP passwords must be 80 characters or fewer. See [Calico BGP security docs](https://docs.tigera.io/calico/latest/network-policy/comms/secure-bgp) for details.

**Uninstall k3s:**
```bash
/usr/local/bin/k3s-killall.sh
/usr/local/bin/k3s-uninstall.sh
```

### Cluster Access

**Get kubeconfig from server node:**
```bash
# On server node
cat /etc/rancher/k3s/k3s.yaml

# Copy to local machine at ~/.kube/config
# Change server URL to use node hostname or IPv6 address
```

**Verify cluster networking:**
```bash
kubectl get pods --all-namespaces -o wide
kubectl get nodes -o wide

# Test CoreDNS resolution
nslookup metrics-server.kube-system.svc.k8s.lzadm.com <cluster-dns-ip>

# Check Calico status
kubectl get installation -o yaml
kubectl get ippools
```

## Key Script Behaviors

### k3s-server-config-set.sh
- Detects primary IPv6 interface and stable global address (excludes temporary/privacy addresses)
- Extracts first 3 hextets as /48 prefix (e.g., `2001:a61:1162`)
- Uses hardcoded `79fd` as fourth hextet for cluster-cidr (separate from host network `79fc`)
- Generates `/etc/rancher/k3s/config.yaml` with:
  - `cluster-cidr: <prefix>:79fd::/64`
  - `service-cidr: <prefix>:79fd:ff00::/112`
  - `cluster-dns: <prefix>:79fd:ff00::10`
- Must be run BEFORE k3s installation

### k3s-agent-config-set.sh
- Similar to server script but generates minimal config (no cluster/service CIDR)
- Only sets node IP and disables default networking

### nsupdate-pfsense-bind.sh
- Auto-discovers IPv6 address, DNS server, and search domain
- Updates AAAA record in pfSense BIND9 zone via nsupdate
- Uses port 5353 (non-standard BIND9 port on pfSense)
- Should be run after each node boot if using DHCP-like SLAAC

### generalize_debian.sh
- Removes unique identifiers (machine-id, SSH keys, DHCP leases)
- Clears logs and temporary files
- Prepares VM for snapshot/cloning
- Run before taking template snapshot

## Troubleshooting

**Pods stuck in ContainerCreating:**
- Missing CNI - install Calico
- Check: `kubectl describe pod <pod-name>`

**No network connectivity in pods:**
- Verify Calico installation: `kubectl get pods -n calico-system`
- Check IP pools: `kubectl get ippools -o yaml`
- Verify BGP peering: `kubectl get bgppeer -o yaml`

**DNS resolution failures:**
- Check CoreDNS pods: `kubectl get pods -n kube-system | grep coredns`
- Verify cluster DNS IP in k3s config matches CoreDNS service

**BGP routes not advertised:**
- Verify BGP peer configuration on pfSense
- Check Calico BGP configuration: `kubectl get bgpconfig -o yaml`
- Ensure service CIDR is correctly configured in BGPConfiguration
- Verify pfSense receives BGP routes for cluster CIDR subnet (79fd::/64)
- Check pfSense FRR BGP config allows routes from k8s peer group

**Cluster-CIDR overlap errors during k3s installation:**
- Ensure cluster-cidr uses a different /64 than the node network
- Verify `k3s-server-config-set.sh` generates `79fd` for cluster-cidr (not `79fc`)
- Do not reuse the same /64 that pfSense advertises via RA for host addresses
