# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

IPv6-only Kubernetes cluster home lab setup running k3s on Debian 13 VMs in VMware Fusion on macOS. The cluster uses DNS64/NAT64 on pfSense for IPv4 connectivity, Calico CNI for networking, and BGP peering with pfSense for service advertisement.

**Key Infrastructure:**
- **Network:** Dual-stack ULA + GUA (ULA for internal stability, GUA for external LoadBalancers)
- **Router:** pfSense with DNS64/NAT64, FRR BGP (AS 65101), BIND9 on port 5353
- **Cluster:** k3s multi-node with Calico CNI, BGP peering (AS 65010)
- **DNS:**
  - Cluster domain: `k8s.lzadm.com` (CoreDNS authoritative for cluster services)
  - Home domain: `home.lzadm.com` (BIND on pfSense)
  - ExternalDNS manages LoadBalancer records in BIND via RFC2136

**ISP Prefix Resilience:**
The cluster uses ULA (Unique Local Addresses) for internal networking, making it resilient to ISP IPv6 prefix changes. Only LoadBalancer IPs use GUA (Global Unicast Addresses) from the ISP.

**Network Topology:**
```
[ISP DSLite /56: 2001:a61:XXXX::/56]  ← Changes with ISP prefix delegation
              │
              ▼
        [Fritzbox] ── DHCPv6-PD ──┬──▶ [Mikrotik hex-s]  GUA /60
                                  ├──▶ [Unifi UDR7]      GUA /64
                                  └──▶ [pfSense]         GUA /64
                                           │
                                           ├── GUA /64 → host network (RA)
                                           └── ULA fd77:3be9:5d2e:1::/64 → k8s nodes (RA)
                                                  │
                                        ┌─────────┴─────────┐
                                        │    k3s Cluster    │
                                        │                   │
                                        │  ULA (stable):    │
                                        │  └─ nodes, pods,  │
                                        │     ClusterIPs,   │
                                        │     BGP peers     │
                                        │                   │
                                        │  GUA (dynamic):   │
                                        │  └─ LoadBalancer  │
                                        │     IPs only      │
                                        └───────────────────┘
```

**Address Types:**
| Type | Prefix | Stability | Usage |
|------|--------|-----------|-------|
| ULA | `fd77:3be9:5d2e::/48` | Permanent | Nodes, pods, ClusterIPs, BGP |
| GUA | `2001:a61:XXXX:YYYY::/64` | Changes with ISP | LoadBalancer IPs only |

**ULA Subnet Allocation:**
| Prefix | Assignment | Notes |
|--------|------------|-------|
| fd77:3be9:5d2e:1::/64 | Node network | Via RA from pfSense |
| fd77:3be9:5d2e:ffcc::/112 | k3s cluster-cidr | Pod network (65,536 IPs) |
| fd77:3be9:5d2e:ff00::/112 | k3s service-cidr | ClusterIP services |
| `<GUA>`:ff01::/112 | k3s LoadBalancer | LoadBalancer IPs (changes with ISP) |

## Architecture

### VM Deployment Strategy
- **Parent VM:** Debian 13 template with systemd-networkd, generalized for cloning
- **Linked Clones:** VMs created from parent snapshot to save disk space
- **Node Types:**
  - Server nodes (control plane): use `k3s-server-config-set.sh`
  - Agent nodes (workers): use `k3s-agent-config-set.sh`

### IPv6 Network Configuration (ULA + GUA Hybrid)

**ISP Prefix Resilience Architecture:**
This setup uses ULA for internal cluster networking and GUA for external LoadBalancer services. When the ISP changes the delegated prefix, only LoadBalancer IPs need updating—the cluster continues operating without disruption.

**ULA Prefix:** `fd77:3be9:5d2e::/48` (permanent, never changes)
**GUA Prefix:** `2001:a61:XXXX:YYYY::/64` (changes with ISP prefix delegation)

**How it works:**
- pfSense receives GUA `/64` via DHCPv6-PD from Fritzbox
- pfSense advertises BOTH the GUA /64 AND ULA `fd77:3be9:5d2e:1::/64` via Router Advertisements
- Nodes receive dual-stack addresses: ULA for cluster traffic, GUA for internet access
- k3s uses ULA for node-ip, cluster-cidr, and service-cidr (stable)
- MetalLB uses GUA for LoadBalancer pool (must be updated when ISP prefix changes)
- BGP peering uses ULA addresses (stable across prefix changes)
- **BGPFilter** controls which routes are advertised to pfSense (rejects pod CIDR)

**What uses ULA (stable):**
- Node IPs for k3s (`fd77:3be9:5d2e:1::XXXX`)
- Pod network (`fd77:3be9:5d2e:ffcc::/112`)
- ClusterIP services (`fd77:3be9:5d2e:ff00::/112`)
- BGP peer addresses
- pfSense BIND server (`fd77:3be9:5d2e:1::1`)

**What uses GUA (changes with ISP):**
- LoadBalancer IPs (`<GUA-prefix>:ff01::/112`)
- Pod outbound NAT66 (if configured)
- DNS records for LoadBalancer services (auto-updated by ExternalDNS)

**Node network:**
- Nodes use systemd-networkd for IPv6 SLAAC (Stateless Address Autoconfiguration)
- Nodes receive BOTH ULA and GUA addresses via router advertisements from pfSense
- k3s uses ULA address for node-ip (stable across ISP prefix changes)
- DNS registration via `nsupdate-pfsense-bind.sh` to pfSense BIND9 (port 5353)

### k3s Cluster Architecture
- **Networking:** Calico CNI replaces built-in Flannel (disabled)
- **Service Advertisement:** Calico BGP peers with pfSense over ULA to advertise cluster services
- **Load Balancing:** MetalLB assigns GUA LoadBalancer IPs from ISP prefix
- **Storage:** local-path-provisioner (built-in k3s)

### Network Parameters

**Fixed ULA Configuration (never changes):**
```
ULA Prefix:     fd77:3be9:5d2e::/48
Node network:   fd77:3be9:5d2e:1::/64 (via RA from pfSense)
Cluster CIDR:   fd77:3be9:5d2e:ffcc::/112 (pods)
Service CIDR:   fd77:3be9:5d2e:ff00::/112 (ClusterIP)
Cluster DNS:    fd77:3be9:5d2e:ff00::10
Per-node CIDR:  /120 (256 pod IPs per node, supports 256 nodes)
pfSense BIND:   fd77:3be9:5d2e:1::1:5353
BGP Peer:       fd77:3be9:5d2e:1::1 (pfSense)
```

**Dynamic GUA Configuration (changes with ISP):**
```
GUA Prefix:      <current-ISP-prefix>::/64 (e.g., 2001:a61:35b3:cdfa::/64)
LoadBalancer:    <GUA-prefix>:ff01::/112 (MetalLB pool)
```

**Example addresses:**
```
Node ULA:       fd77:3be9:5d2e:1:abc:def:123:456
Node GUA:       2001:a61:35b3:cdfa:abc:def:123:456
Pod IP:         fd77:3be9:5d2e:ffcc::1234
ClusterIP:      fd77:3be9:5d2e:ff00::5678
LoadBalancer:   2001:a61:35b3:cdfa:ff01::1
```

**Important:** The script `k3s-server-config-set.sh` uses a fixed ULA prefix for cluster networking. This makes the cluster immune to ISP prefix changes—only the MetalLB LoadBalancer pool needs updating when the prefix changes.

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
- **Dual-stack LAN configuration:**
  - GUA /64 from DHCPv6-PD (advertised via RA)
  - ULA Virtual IP: `fd77:3be9:5d2e:1::1/64` (advertised via RA)
- **Router Advertisements** advertising BOTH prefixes to k8s VMs
- DNS64/NAT64 configured for IPv4 reachability from IPv6-only hosts
- BIND9 running on ULA address (`fd77:3be9:5d2e:1::1:5353`) for dynamic DNS updates
- FRR package installed and configured for BGP (AS 65101)
- BGP peer group configured to accept connections from ULA range (`fd77:3be9:5d2e:1::/64`)

**pfSense ULA Configuration:**
1. Interfaces → LAN → Add Virtual IP: `fd77:3be9:5d2e:1::1/64`
2. Services → Router Advertisement → LAN:
   - Advertise both GUA and ULA prefixes
   - ULA prefix: `fd77:3be9:5d2e:1::/64`
3. Services → BIND DNS:
   - Listen on `fd77:3be9:5d2e:1::1` (port 5353)
4. FRR BGP Configuration:
   ```
   router bgp 65101
     neighbor k8s peer-group
     neighbor k8s remote-as 65010
     bgp listen range fd77:3be9:5d2e:1::/64 peer-group k8s
     address-family ipv6 unicast
       neighbor k8s activate
   ```

**Optional NAT66 for Pod Outbound:**
If pods need to initiate connections to the internet:
- Create NPt (Network Prefix Translation) rule on pfSense
- Internal: `fd77:3be9:5d2e:ffcc::/112` (pod CIDR)
- External: Use current GUA prefix
- Direction: Outbound only

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

# Configure Calico with ULA IPv6 pool (stable across ISP prefix changes)
kubectl create -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - blockSize: 120
        cidr: fd77:3be9:5d2e:ffcc::/112
        encapsulation: None
        natOutgoing: Disabled
        nodeSelector: all()
    nodeAddressAutodetectionV6:
      # Detect ULA addresses for node IPs
      cidrs:
        - "fd77:3be9:5d2e:1::/64"
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
# Get current GUA prefix for LoadBalancer pool (changes with ISP)
GUA_IP=$(ip -6 addr show scope global | awk '/inet6/ {print $2}' | cut -d/ -f1 | grep -v '^fd' | grep -v '^fc' | grep -v '^fe80' | head -1)
GUA_PREFIX=$(echo $GUA_IP | cut -d: -f1-4)

echo "ULA prefix (stable):     fd77:3be9:5d2e"
echo "GUA prefix (from ISP):   $GUA_PREFIX"
echo "LoadBalancer pool:       ${GUA_PREFIX}:ff01::/112"

# 1. Configure Calico BGP with ULA service CIDR and GUA LoadBalancer pool
kubectl apply -f - <<EOF
apiVersion: projectcalico.org/v3
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: 65010
  serviceClusterIPs:
    # ClusterIP services use ULA (stable)
    - cidr: fd77:3be9:5d2e:ff00::/112
  serviceLoadBalancerIPs:
    # LoadBalancer IPs use GUA (update this when ISP prefix changes)
    - cidr: ${GUA_PREFIX}:ff01::/112
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

# 4. Create BGPFilter to control route advertisements
kubectl apply -f - <<EOF
apiVersion: projectcalico.org/v3
kind: BGPFilter
metadata:
  name: pfsense-export-filter
spec:
  exportV6:
    # Reject pod CIDR advertisements to pfSense (not needed on router)
    - action: Reject
      matchOperator: In
      cidr: fd77:3be9:5d2e:ffcc::/112
    # Default action is Accept - ClusterIP (ULA) and LoadBalancer (GUA) pass through
EOF

# 5. Add pfSense as BGP peer using ULA address (stable across ISP changes)
kubectl apply -f - <<EOF
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata:
  name: pfsense
spec:
  # Use pfSense ULA address (stable, never changes)
  peerIP: fd77:3be9:5d2e:1::1
  asNumber: 65101
  password:
    secretKeyRef:
      name: bgp-secrets
      key: pfsense-password
  filters:
    - pfsense-export-filter
EOF
```

**BGPFilter Benefits:**
- **Reduces routing table size** on pfSense by filtering unnecessary pod routes
- **Accepts service CIDR** (ff00::/112) for ClusterIP services
- **Accepts LoadBalancer IPs** (ff01::/112) for external service access
- **Rejects pod CIDR** (ffcc::/112) as pod routes don't need to be on pfSense

**Note:** BGP passwords must be 80 characters or fewer. See [Calico BGP security docs](https://docs.tigera.io/calico/latest/network-policy/comms/secure-bgp) for details.

**Uninstall k3s:**
```bash
/usr/local/bin/k3s-killall.sh
/usr/local/bin/k3s-uninstall.sh
```

### Cluster Access

**Recommended: Use API LoadBalancer for HA access**

For reliable, resilient cluster management, use a LoadBalancer service for the Kubernetes API. This provides automatic failover between server nodes.

See [k3s-api-loadbalancer.md](k3s-api-loadbalancer.md) for complete setup guide.

**Quick setup:**
```bash
# Get current GUA prefix for LoadBalancer IP
GUA_PREFIX=$(ip -6 addr show scope global | awk '/inet6/ {print $2}' | cut -d/ -f1 | grep -v '^fd' | grep -v '^fc' | grep -v '^fe80' | head -1 | cut -d: -f1-4)

# Convert kubernetes service to LoadBalancer with GUA IP
kubectl patch svc kubernetes -p "{\"spec\":{\"type\":\"LoadBalancer\",\"loadBalancerIP\":\"${GUA_PREFIX}:ff01::1\"}}"
kubectl annotate svc kubernetes external-dns.alpha.kubernetes.io/hostname=api.k8s.lzadm.com

# Update kubeconfig to use LoadBalancer DNS name (resilient to prefix changes)
kubectl config set-cluster default --server=https://api.k8s.lzadm.com:443
```

**Note:** The API LoadBalancer IP will change when the ISP prefix changes, but `api.k8s.lzadm.com` will be automatically updated by ExternalDNS.

**Alternative: Direct node access**

Get kubeconfig from server node:
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

# Verify BGP configuration and filters
calicoctl get bgpconfig -o yaml
calicoctl get bgpfilter -o yaml
calicoctl get bgppeer -o yaml
calicoctl node status
```

## External Access via Cloudflare Tunnels

Cloudflare Tunnels provide secure external access to cluster services without exposing public IPs or opening firewall ports. The tunnel creates an outbound-only connection from the cluster to Cloudflare's edge network.

**Benefits:**
- No public IPv4/IPv6 addresses required
- No firewall port forwarding needed
- Automatic DDoS protection via Cloudflare
- Free SSL/TLS certificates
- Works with IPv6-only clusters

### Prerequisites

- Cloudflare account with a domain
- `cloudflared` CLI tool installed on a management machine

### Installation Steps

#### 1. Install cloudflared CLI (on management machine or node)

```bash
# Add Cloudflare GPG key
sudo mkdir -p --mode=0755 /etc/apt/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /etc/apt/keyrings/cloudflare-public-v2.gpg >/dev/null

# Add repository
echo 'deb [signed-by=/etc/apt/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list

# Install cloudflared
sudo apt-get update && sudo apt-get install cloudflared
```

#### 2. Authenticate with Cloudflare

```bash
cloudflared tunnel login
# Opens browser to authenticate with Cloudflare account
# Credentials saved to ~/.cloudflared/cert.pem
```

Output:
```
Please open the following URL and log in with your Cloudflare account:
https://dash.cloudflare.com/argotunnel?aud=&callback=...

You have successfully logged in.
If you wish to copy your credentials to a server, they have been saved to:
/root/.cloudflared/cert.pem
```

#### 3. Create Tunnel

```bash
cloudflared tunnel create k8s-lzadm-com-tunnel
```

Output:
```
Tunnel credentials written to /root/.cloudflared/b34831d9-1608-4ecc-b2cc-c0b13c7e195f.json
Created tunnel k8s-lzadm-com-tunnel with id b34831d9-1608-4ecc-b2cc-c0b13c7e195f
```

**Important:** Keep the credentials file secure - it provides access to your tunnel.

#### 4. Create Kubernetes Secret with Tunnel Credentials

```bash
kubectl create secret generic tunnel-credentials \
  --from-file=credentials.json=/root/.cloudflared/b34831d9-1608-4ecc-b2cc-c0b13c7e195f.json
```

#### 5. Deploy cloudflared to Kubernetes

Deploy as a DaemonSet to ensure tunnel availability across nodes:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cloudflared
  namespace: default
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
        # Force IPv6 for Cloudflare edge connections
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
  namespace: default
data:
  config.yaml: |
    tunnel: k8s-lzadm-com-tunnel
    credentials-file: /etc/cloudflared/creds/credentials.json
    metrics: 0.0.0.0:2000
    no-autoupdate: true
    ingress:
    # Map external hostname to internal k8s service
    - hostname: "whoami.slawa.uk"
      service: http://whoami.default.svc.k8s.lzadm.com:80
    # Catch-all rule (required as last entry)
    - service: http_status:404
EOF
```

**Configuration Notes:**
- `--edge-ip-version: "6"` - Forces IPv6 for Cloudflare edge connections (works with IPv6-only cluster)
- `tunnel: k8s-lzadm-com-tunnel` - Tunnel name created in step 3
- `credentials-file` - Path to tunnel credentials in the secret
- `ingress` - Maps external hostnames to internal k8s services
- Last `ingress` entry must be a catch-all rule

#### 6. Create DNS Route

Map your domain to the tunnel:

```bash
cloudflared tunnel route dns k8s-lzadm-com-tunnel "whoami.slawa.uk"
```

This creates a CNAME record in Cloudflare DNS pointing to the tunnel.

### Verification

```bash
# Check cloudflared pods
kubectl get pods -l app=cloudflared -o wide

# Check cloudflared logs
kubectl logs -l app=cloudflared --tail=50

# Check tunnel metrics
kubectl run -it --rm curl --image=curlimages/curl --restart=Never -- \
  curl http://cloudflared.default.svc.k8s.lzadm.com:2000/metrics

# Test external access
curl https://whoami.slawa.uk
```

### Adding More Services

Edit the ConfigMap to add more ingress rules:

```bash
kubectl edit configmap cloudflared
```

Add new entries before the catch-all rule:

```yaml
ingress:
- hostname: "app1.slawa.uk"
  service: http://app1.default.svc.k8s.lzadm.com:80
- hostname: "app2.slawa.uk"
  service: http://app2.default.svc.k8s.lzadm.com:443
  originServerName: app2.slawa.uk
- hostname: "whoami.slawa.uk"
  service: http://whoami.default.svc.k8s.lzadm.com:80
- service: http_status:404
```

Then create DNS routes:

```bash
cloudflared tunnel route dns k8s-lzadm-com-tunnel "app1.slawa.uk"
cloudflared tunnel route dns k8s-lzadm-com-tunnel "app2.slawa.uk"
```

### Troubleshooting

**Tunnel not connecting:**
```bash
# Check pod status
kubectl describe pods -l app=cloudflared

# Check logs for errors
kubectl logs -l app=cloudflared

# Common issues:
# - Incorrect credentials: verify secret contains correct credentials.json
# - Tunnel name mismatch: ensure config.yaml tunnel name matches created tunnel
# - Network connectivity: verify IPv6 connectivity to Cloudflare edge
```

**DNS not resolving:**
```bash
# Verify DNS route exists
cloudflared tunnel route dns list

# Check Cloudflare DNS records
# Login to Cloudflare dashboard → DNS → Records
# Should see CNAME record pointing to tunnel
```

**Service not accessible:**
```bash
# Verify service exists and is accessible from pod
kubectl run -it --rm curl --image=curlimages/curl --restart=Never -- \
  curl http://whoami.default.svc.k8s.lzadm.com:80

# Check ingress configuration in ConfigMap
kubectl get configmap cloudflared -o yaml
```

### Security Considerations

- **Credentials:** Tunnel credentials provide full access to the tunnel - protect the Kubernetes secret
- **Ingress rules:** Only expose necessary services
- **Cloudflare Access:** Consider using Cloudflare Access for authentication
- **Rate limiting:** Configure Cloudflare rate limiting rules to prevent abuse

### Alternative: Deployment vs DaemonSet

For high availability without running on every node, use a Deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cloudflared
  template:
    # ... same template as DaemonSet
```

**DaemonSet vs Deployment:**
- **DaemonSet:** Runs on all nodes, maximum availability, more resource usage
- **Deployment:** Runs fixed replicas, lower resource usage, sufficient for most cases

## DNS Management with ExternalDNS

ExternalDNS automatically manages DNS records in pfSense BIND for Kubernetes LoadBalancer services, enabling home network devices to resolve cluster service names.

### DNS Architecture

**CoreDNS vs BIND separation:**

```
┌─────────────────────────────────────────────────────────────────┐
│  DNS Authority Split                                             │
├─────────────────────────────────────────────────────────────────┤
│  Zone: k8s.lzadm.com                                            │
│  ├── CoreDNS (internal): ClusterIPs                             │
│  │   - *.svc.k8s.lzadm.com → service discovery                  │
│  │   - *.pod.k8s.lzadm.com → pod IPs                            │
│  │   - Forwards non-cluster queries to pfSense BIND             │
│  │                                                              │
│  └── BIND (external): LoadBalancer IPs only                     │
│      - whoami.k8s.lzadm.com → LB IP (managed by ExternalDNS)    │
│      - app.k8s.lzadm.com → LB IP                                │
│      - (NOT all cluster services - only exposed)                │
├─────────────────────────────────────────────────────────────────┤
│  Zone: home.lzadm.com                                           │
│  └── BIND only (pfSense)                                        │
│      - k8s-node01.home → node IPs (via nsupdate script)         │
│      - pfsense.home → router IP                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Key principles:**
- **CoreDNS** is authoritative for cluster domain (`k8s.lzadm.com`) inside the cluster
- **BIND** on pfSense handles external queries and LoadBalancer service records
- **ExternalDNS** automatically syncs LoadBalancer services to BIND via RFC2136
- Pod queries for cluster services resolve internally (fast, no external lookup)
- Home network queries for exposed services resolve via BIND

### ExternalDNS Setup

ExternalDNS uses RFC2136 (Dynamic DNS Updates) with TSIG authentication to manage records in pfSense BIND.

**Prerequisites:**
- pfSense BIND running on port 5353
- TSIG key configured in BIND
- `k8s.lzadm.com` zone allowing dynamic updates

**Installation:**

See [k3s-external-dns-pfsense.md](k3s-external-dns-pfsense.md) for complete setup guide.

Quick setup:

```bash
# 1. Generate TSIG key on pfSense
tsig-keygen -a hmac-sha256 externaldns-key

# 2. Configure BIND zone for dynamic updates (see k3s-external-dns-pfsense.md)

# 3. Deploy ExternalDNS
kubectl apply -f external-dns-rfc2136.yaml
```

**Usage:**

Add annotation to any LoadBalancer service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
  annotations:
    external-dns.alpha.kubernetes.io/hostname: myapp.k8s.lzadm.com
spec:
  type: LoadBalancer
  selector:
    app: myapp
  ports:
    - port: 80
```

ExternalDNS will automatically:
1. Detect the service and its LoadBalancer IP
2. Create DNS record in pfSense BIND: `myapp.k8s.lzadm.com → 2001:a61:1162:79fb:ff01::X`
3. Create TXT ownership record for tracking
4. Update/delete records when service changes or is removed

**Verify:**

```bash
# Check ExternalDNS logs
kubectl logs -n external-dns -l app=external-dns

# Query DNS record using ULA address (stable)
dig @fd77:3be9:5d2e:1::1 -p 5353 myapp.k8s.lzadm.com AAAA +short

# From home network
dig myapp.k8s.lzadm.com AAAA +short
```

### CoreDNS Configuration

CoreDNS is configured to:
- Be authoritative for `k8s.lzadm.com`
- Forward non-cluster queries to pfSense BIND
- Maintain node hostname mappings

**Verify CoreDNS:**

```bash
# Check CoreDNS config
kubectl get configmap coredns -n kube-system -o yaml

# Test cluster service resolution
kubectl run -it --rm debug --image=busybox --restart=Never -- \
  nslookup kubernetes.default.svc.k8s.lzadm.com

# Test external DNS resolution (via BIND)
kubectl run -it --rm debug --image=busybox --restart=Never -- \
  nslookup pfsense.home.lzadm.com
```

### Rotating TSIG Secret

To regenerate the TSIG key for security rotation:

```bash
# 1. Generate new key on pfSense
tsig-keygen -a hmac-sha256 externaldns-key

# 2. Update BIND configuration on pfSense

# 3. Update Kubernetes secret
kubectl patch secret external-dns-rfc2136 -n external-dns \
  -p '{"stringData":{"tsig-secret":"NEW_SECRET_HERE"}}'

# 4. Restart ExternalDNS
kubectl rollout restart deployment/external-dns -n external-dns
```

See [k3s-external-dns-pfsense.md](k3s-external-dns-pfsense.md#rotatingupdating-tsig-secret) for detailed steps.

## Key Script Behaviors

### k3s-server-config-set.sh
- Uses fixed ULA prefix `fd77:3be9:5d2e` for all internal cluster networking
- Detects node's ULA address from SLAAC (must match prefix `fd77:3be9:5d2e`)
- Also detects GUA address for reference (used for LoadBalancer pool suggestion)
- Generates `/etc/rancher/k3s/config.yaml` with:
  - `node-ip: <ULA-address>` (stable across ISP prefix changes)
  - `cluster-cidr: fd77:3be9:5d2e:ffcc::/112` (stable)
  - `service-cidr: fd77:3be9:5d2e:ff00::/112` (stable)
  - `cluster-dns: fd77:3be9:5d2e:ff00::10` (stable)
- Must be run BEFORE k3s installation
- Outputs suggested LoadBalancer pool CIDR based on current GUA prefix

### k3s-agent-config-set.sh
- Uses fixed ULA prefix `fd77:3be9:5d2e` for node-ip detection
- Generates minimal config with ULA node-ip
- Must be run BEFORE k3s agent installation

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

## ISP Prefix Change Procedure

When the ISP changes your delegated IPv6 prefix (e.g., from `2001:a61:1162:79fb::` to `2001:a61:35b3:cdfa::`), only a few components need updating. The cluster continues operating because internal networking uses stable ULA addresses.

**What changes:**
- LoadBalancer IPs (MetalLB pool)
- DNS records for LoadBalancer services (auto-updated by ExternalDNS)
- NAT66 rule (if configured for pod outbound)

**What stays the same:**
- Node IPs (ULA)
- Pod IPs (ULA)
- ClusterIP services (ULA)
- BGP peer addresses (ULA)
- pfSense BIND address (ULA)

### Procedure

1. **Detect the new GUA prefix:**
   ```bash
   # On any node
   GUA_IP=$(ip -6 addr show scope global | awk '/inet6/ {print $2}' | cut -d/ -f1 | grep -v '^fd' | grep -v '^fc' | grep -v '^fe80' | head -1)
   NEW_GUA_PREFIX=$(echo $GUA_IP | cut -d: -f1-4)
   echo "New GUA prefix: $NEW_GUA_PREFIX"
   echo "New LoadBalancer pool: ${NEW_GUA_PREFIX}:ff01::/112"
   ```

2. **Update Calico BGPConfiguration (serviceLoadBalancerIPs):**
   ```bash
   calicoctl patch bgpconfiguration default -p "{\"spec\":{\"serviceLoadBalancerIPs\":[{\"cidr\":\"${NEW_GUA_PREFIX}:ff01::/112\"}]}}"
   ```

3. **Update MetalLB IPAddressPool:**
   ```bash
   kubectl patch ipaddresspool default -n metallb-system --type=merge -p "{\"spec\":{\"addresses\":[\"${NEW_GUA_PREFIX}:ff01::/112\"]}}"
   ```

4. **Update NAT66 rule on pfSense (if using pod outbound NAT):**
   - Navigate to Firewall → NAT → NPt
   - Update the external prefix to match the new GUA

5. **Verify LoadBalancer services get new IPs:**
   ```bash
   kubectl get svc --all-namespaces -o wide | grep LoadBalancer
   ```

6. **ExternalDNS auto-updates DNS records:**
   ```bash
   # Check ExternalDNS logs
   kubectl logs -n external-dns -l app=external-dns --tail=50

   # Verify DNS records
   dig api.k8s.lzadm.com AAAA +short
   ```

**No cluster restart required!** The cluster continues operating throughout the prefix change. Only external access via LoadBalancer IPs is briefly affected while DNS propagates.

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
- Check Calico BGP configuration: `calicoctl get bgpconfig -o yaml`
- Ensure service CIDR is correctly configured in BGPConfiguration
- Check BGP peer status: `calicoctl node status`
- Verify pfSense receives expected BGP routes (service CIDR, LoadBalancer IPs)
- Check pfSense FRR BGP config allows routes from k8s peer group

**BGPFilter not working:**
- Verify BGPFilter resource exists: `calicoctl get bgpfilter -o yaml`
- Check BGPPeer has filter attached: `calicoctl get bgppeer pfsense -o yaml | grep -A2 filters`
- Ensure filter rules are correctly configured (action, matchOperator, cidr)
- On pfSense FRR shell, verify pod routes are NOT present: `show bgp ipv6 unicast`
- Check Calico logs for BGP filter errors: `kubectl logs -n calico-system -l k8s-app=calico-node`

**Cluster-CIDR overlap errors during k3s installation:**
- Ensure cluster-cidr uses a different /64 than the node network
- Verify `k3s-server-config-set.sh` generates `79fd` for cluster-cidr (not `79fc`)
- Do not reuse the same /64 that pfSense advertises via RA for host addresses

**ExternalDNS not creating records:**
- Check ExternalDNS logs: `kubectl logs -n external-dns -l app=external-dns`
- Verify service has LoadBalancer IP assigned: `kubectl get svc`
- Check service has hostname annotation: `external-dns.alpha.kubernetes.io/hostname`
- Verify TSIG authentication: test with `nsupdate` manually
- Check BIND allows updates: review `/var/log/resolver.log` on pfSense
- Ensure ExternalDNS can reach BIND on port 5353

**DNS records not resolving from home network:**
- Query BIND directly: `dig @pfsense-ip -p 5353 hostname.k8s.lzadm.com AAAA`
- Check home DNS server forwards to pfSense BIND
- Verify LoadBalancer IP is reachable from home network
- Check BGP advertised LoadBalancer CIDR to pfSense

**Kubernetes service reverts to ClusterIP after k3s restart:**
- k3s recreates the default `kubernetes` service as ClusterIP on startup
- Manual patches are lost after restart
- **Solution:** Use k3s auto-apply manifests in `/var/lib/rancher/k3s/server/manifests/`
- See [k3s-api-loadbalancer.md](k3s-api-loadbalancer.md#permanent-solution-auto-apply-manifest) for detailed fix

**LoadBalancer IP not assigned to kubernetes service:**
- Check if auto-apply manifest exists: `/var/lib/rancher/k3s/server/manifests/kubernetes-api-loadbalancer.yaml`
- Verify MetalLB pool has IPs available: `kubectl get ipaddresspool -n metallb-system`
- Check MetalLB controller logs: `kubectl logs -n metallb-system -l component=controller`
