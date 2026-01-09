# k3s Control Plane High Availability Options

This document compares two approaches for k3s control plane HA in an IPv6-only environment.

## Environment Context

- **Cluster**: k3s multi-node on Debian 13
- **Network**: IPv6-only (2001:a61:1162:79fb::/64)
- **CNI**: Calico with BGP peering to pfSense
- **Existing BGP**: Calico AS 65010 → pfSense AS 65101
- **DNS**: pfSense BIND9 on port 5353

## Architecture Overview

### Current Setup (No HA)

```
Client (kubectl)
      │
      ▼
k8s-node01:6443  ← Single point of failure
      │
      ├── k8s-node02 (server)
      └── k8s-node03 (server)
```

### Goal: Highly Available Control Plane

```
Client (kubectl)
      │
      ▼
   VIP or DNS  ← Abstraction layer
      │
      ├── k8s-node01:6443
      ├── k8s-node02:6443
      └── k8s-node03:6443
```

---

## Option 1: MetalLB IPv6 BGP (FRR Mode)

### How It Works

MetalLB in FRR mode provides a virtual IP (VIP) that floats between nodes. When a node fails, BGP withdraws the route and traffic flows to healthy nodes.

```
┌─────────────────────────────────────────────────────────────┐
│                  pfSense (AS 65101, FRR)                    │
│                                                             │
│  BGP Routes Learned (after pfsense-export-filter):          │
│  - 2001:a61:1162:79fb:ff00::/112  (svc network - Calico)   │
│  - 2001:a61:1162:79fb:ff00::100   (API VIP - Calico)       │
│                                                             │
│  FILTERED OUT:                                              │
│  - 2001:a61:1162:79fb:ffcc::/112  (pod network - rejected) │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ BGP (AS 65010)
                          │ + BGPFilter
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
        ▼                 ▼                 ▼
  ┌───────────┐    ┌───────────┐    ┌───────────┐
  │k8s-node01 │    │k8s-node02 │    │k8s-node03 │
  │           │    │           │    │           │
  │ Calico    │    │ Calico    │    │ Calico    │
  │+BGPFilter │    │+BGPFilter │    │+BGPFilter │
  │           │    │           │    │           │
  │ API :6443 │    │ API :6443 │    │ API :6443 │
  └───────────┘    └───────────┘    └───────────┘
        │                 │                 │
        └─────────────────┴─────────────────┘
                          │
                    VIP: 2001:a61:1162:79fb:ff00::100
```

### IPv6 Support

- MetalLB FRR mode **required** for IPv6 (native mode doesn't support IPv6)
- Full dual-stack and IPv6-only support in FRR mode
- BFD (Bidirectional Forwarding Detection) available for faster failover

### Calico Integration

**Key:** Have Calico advertise MetalLB LoadBalancer IPs to avoid BGP session conflicts.

Both Calico and MetalLB use BGP, but only one BGP session per source-destination IP pair is allowed. Solution: Configure Calico to advertise MetalLB service IPs.

**BGPFilter Usage:** Use BGPFilter to control which routes are advertised to pfSense:
- **Reject pod CIDR** (`ffcc::/112`) - pod routes are not needed on pfSense
- **Accept service CIDR** (`ff00::/112`) - for ClusterIP service access
- **Accept LoadBalancer IPs** - for external service access (VIP)

### Installation Steps

#### 1. Install MetalLB FRR Mode

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-frr.yaml

# Wait for pods
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

#### 2. Create IPv6 Address Pool

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: control-plane-pool
  namespace: metallb-system
spec:
  addresses:
  - "2001:a61:1162:79fb:ff00::100/128"  # Single VIP for API server
  autoAssign: false  # Manual assignment only
```

#### 3. Configure Calico to Advertise MetalLB VIP

Update the existing Calico BGPConfiguration:

```yaml
apiVersion: projectcalico.org/v3
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: 65010
  serviceClusterIPs:
  - cidr: 2001:a61:1162:79fb:ff00::/112       # Existing service CIDR
  serviceExternalIPs:
  - cidr: 2001:a61:1162:79fb:ff00::100/128    # MetalLB VIP
```

#### 4. Create BGPFilter to Control Route Advertisements

Create a filter to reject pod CIDR advertisements to pfSense:

```yaml
apiVersion: projectcalico.org/v3
kind: BGPFilter
metadata:
  name: pfsense-export-filter
spec:
  exportV6:
    # Reject pod CIDR advertisements to pfSense
    - action: Reject
      matchOperator: In
      cidr: 2001:a61:1162:79fb:ffcc::/112
    # Default action is Accept - service CIDR and VIP pass through
```

Apply the filter:
```bash
calicoctl apply -f pfsense-export-filter.yaml
```

#### 5. Attach Filter to pfSense BGPPeer

Update your existing BGPPeer to pfSense to use the filter:

```yaml
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
  # Attach the filter
  filters:
    - pfsense-export-filter
```

Apply:
```bash
calicoctl apply -f bgppeer-pfsense.yaml
```

#### 6. Create L2 Advertisement (for local network)

```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: control-plane-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - control-plane-pool
```

#### 7. Update k3s TLS SAN

Add to `/etc/rancher/k3s/config.yaml` on ALL server nodes before installation:

```yaml
tls-san:
  - "k8s-node01"
  - "k8s-node02"
  - "k8s-node03"
  - "k8s-cluster.k8s.lzadm.com"              # HA DNS name
  - "2001:a61:1162:79fb:ff00::100"           # MetalLB VIP
```

If k3s is already installed, update config and restart:

```bash
systemctl restart k3s
```

#### 8. Create LoadBalancer Service for API Server

```yaml
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-api-lb
  namespace: default
  annotations:
    metallb.universe.tf/address-pool: control-plane-pool
spec:
  type: LoadBalancer
  loadBalancerIP: "2001:a61:1162:79fb:ff00::100"
  ports:
  - name: https
    port: 6443
    targetPort: 6443
    protocol: TCP
  # Note: This service routes to the API server via endpoints
  # created by the kubernetes service in the default namespace
```

#### 9. Add DNS Entry for VIP

Add to pfSense BIND9 zone:

```
k8s-api.k8s.lzadm.com.  300  IN  AAAA  2001:a61:1162:79fb:ff00::100
```

#### 10. Update kubeconfig

```yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://[2001:a61:1162:79fb:ff00::100]:6443
    # or: https://k8s-api.k8s.lzadm.com:6443
  name: k3s-ha
```

### Verification

```bash
# Check MetalLB pods
kubectl get pods -n metallb-system

# Check IP address assignment
kubectl get svc kubernetes-api-lb -o wide

# Check BGPFilter is applied
calicoctl get bgpfilter pfsense-export-filter -o yaml

# Check BGPPeer has filter attached
calicoctl get bgppeer pfsense -o yaml | grep -A2 filters

# Check BGP peer status
calicoctl node status

# Check BGP routes on pfSense (In pfSense FRR shell)
show bgp ipv6 unicast
# Should see:
#   - 2001:a61:1162:79fb:ff00::/112 (service CIDR)
#   - 2001:a61:1162:79fb:ff00::100 (VIP)
# Should NOT see:
#   - 2001:a61:1162:79fb:ffcc::/112 (pod CIDR - filtered)

# Test connectivity to VIP
curl -k https://[2001:a61:1162:79fb:ff00::100]:6443/healthz
```

### Pros

| Advantage | Description |
|-----------|-------------|
| Fast failover | <3 seconds via BGP route withdrawal |
| Health detection | BGP automatically detects node failures |
| BFD support | Optional 300ms failover with BFD |
| Network-level LB | True load balancing, not client-side |
| No DNS caching | VIP is routed, not resolved |
| Calico integration | Reuse existing BGP infrastructure |

### Cons

| Disadvantage | Description |
|--------------|-------------|
| Complexity | Additional MetalLB configuration |
| Certificate management | Must add VIP to tls-san |
| Debugging | More components to troubleshoot |
| Resource usage | MetalLB pods consume resources |

---

## Option 2: DNS Round-Robin

### How It Works

Multiple AAAA records point to each control plane node. Clients resolve the name and connect to one of the returned IPs.

```
┌─────────────────────────────────────────────────────────────┐
│                  pfSense BIND9 (port 5353)                  │
│                                                             │
│  k8s-cluster.k8s.lzadm.com:                                │
│    AAAA  2001:a61:1162:79fb:xxxx:xxxx:xxxx:1  (node01)     │
│    AAAA  2001:a61:1162:79fb:xxxx:xxxx:xxxx:2  (node02)     │
│    AAAA  2001:a61:1162:79fb:xxxx:xxxx:xxxx:3  (node03)     │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ DNS Resolution
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
        ▼                 ▼                 ▼
  ┌───────────┐    ┌───────────┐    ┌───────────┐
  │k8s-node01 │    │k8s-node02 │    │k8s-node03 │
  │ API :6443 │    │ API :6443 │    │ API :6443 │
  └───────────┘    └───────────┘    └───────────┘
```

### Client Behavior

When kubectl resolves `k8s-cluster.k8s.lzadm.com`:

1. DNS returns all three IPs (order may be randomized)
2. Client attempts connection to first IP
3. On failure, client times out (30+ seconds)
4. Client retries, possibly with next IP
5. DNS caching affects failover speed

### Configuration Steps

#### 1. Update pfSense BIND9 Zone

Add to your `k8s.lzadm.com` zone file:

```bind
; Individual node records
k8s-node01.k8s.lzadm.com.  300  IN  AAAA  2001:a61:1162:79fb:xxxx:xxxx:xxxx:1
k8s-node02.k8s.lzadm.com.  300  IN  AAAA  2001:a61:1162:79fb:xxxx:xxxx:xxxx:2
k8s-node03.k8s.lzadm.com.  300  IN  AAAA  2001:a61:1162:79fb:xxxx:xxxx:xxxx:3

; Round-robin cluster endpoint (all three servers)
k8s-cluster.k8s.lzadm.com. 60   IN  AAAA  2001:a61:1162:79fb:xxxx:xxxx:xxxx:1
k8s-cluster.k8s.lzadm.com. 60   IN  AAAA  2001:a61:1162:79fb:xxxx:xxxx:xxxx:2
k8s-cluster.k8s.lzadm.com. 60   IN  AAAA  2001:a61:1162:79fb:xxxx:xxxx:xxxx:3
```

**Note:** Lower TTL (60s) reduces failover time but increases DNS queries.

Or use nsupdate script:

```bash
#!/bin/bash
# add-cluster-dns.sh

DNS_SERVER="<pfsense-ipv6>"
ZONE="k8s.lzadm.com"
TTL=60

# Get node IPs (run on each node or provide manually)
NODE1_IP="2001:a61:1162:79fb:xxxx:xxxx:xxxx:1"
NODE2_IP="2001:a61:1162:79fb:xxxx:xxxx:xxxx:2"
NODE3_IP="2001:a61:1162:79fb:xxxx:xxxx:xxxx:3"

nsupdate -p 5353 << EOF
server ${DNS_SERVER}
zone ${ZONE}
update delete k8s-cluster.${ZONE}. AAAA
update add k8s-cluster.${ZONE}. ${TTL} AAAA ${NODE1_IP}
update add k8s-cluster.${ZONE}. ${TTL} AAAA ${NODE2_IP}
update add k8s-cluster.${ZONE}. ${TTL} AAAA ${NODE3_IP}
send
EOF
```

#### 2. Update k3s TLS SAN

Add to `/etc/rancher/k3s/config.yaml` on ALL server nodes:

```yaml
tls-san:
  - "k8s-node01"
  - "k8s-node02"
  - "k8s-node03"
  - "k8s-cluster.k8s.lzadm.com"
```

#### 3. Initialize First Server

```bash
./k3s-server-config-set.sh
curl -sfL https://get.k3s.io | K3S_TOKEN=supersecret! sh -s - server --cluster-init
```

#### 4. Join Additional Servers

```bash
./k3s-server-config-set.sh
curl -sfL https://get.k3s.io | K3S_TOKEN=supersecret! sh -s - server \
  --server https://k8s-cluster.k8s.lzadm.com:6443
```

#### 5. Update kubeconfig

```yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://k8s-cluster.k8s.lzadm.com:6443
  name: k3s-ha
```

### Verification

```bash
# Test DNS resolution returns multiple IPs
dig AAAA k8s-cluster.k8s.lzadm.com @<pfsense-ip> -p 5353

# Should return all three node IPs
;; ANSWER SECTION:
k8s-cluster.k8s.lzadm.com. 60 IN AAAA 2001:a61:1162:79fb:xxxx:xxxx:xxxx:1
k8s-cluster.k8s.lzadm.com. 60 IN AAAA 2001:a61:1162:79fb:xxxx:xxxx:xxxx:2
k8s-cluster.k8s.lzadm.com. 60 IN AAAA 2001:a61:1162:79fb:xxxx:xxxx:xxxx:3

# Test kubectl connectivity
kubectl --server=https://k8s-cluster.k8s.lzadm.com:6443 get nodes
```

### Pros

| Advantage | Description |
|-----------|-------------|
| Simple setup | Just DNS records, no extra components |
| No conflicts | Works alongside Calico BGP |
| Low overhead | No additional pods or services |
| Easy debugging | Standard DNS troubleshooting |
| Native k3s | Uses built-in k3s HA mechanism |

### Cons

| Disadvantage | Description |
|--------------|-------------|
| Slow failover | 30-120+ seconds (client timeout + DNS) |
| No health check | DNS doesn't know if node is down |
| DNS caching | OS/client caching delays failover |
| Client-dependent | Different clients handle multi-IP differently |
| TTL tradeoff | Low TTL = more queries, high TTL = slow failover |

---

## Comparison Summary

| Aspect | MetalLB FRR BGP | DNS Round-Robin |
|--------|-----------------|-----------------|
| **Failover time** | <3 seconds | 30-120+ seconds |
| **Setup complexity** | High | Low |
| **Health detection** | Yes (BGP/BFD) | No |
| **IPv6 support** | Full (FRR mode) | Full |
| **Calico conflict** | None (integrated) | None |
| **Certificate changes** | Add VIP to tls-san | Add DNS to tls-san |
| **DNS TTL issues** | None | Major factor |
| **Load balancing** | Network-level | Client-side |
| **Additional components** | MetalLB pods | None |
| **Debugging complexity** | Higher | Lower |

## Failure Scenarios

| Scenario | MetalLB Recovery | DNS Recovery |
|----------|------------------|--------------|
| Single node failure | <3s (BGP withdrawal) | 30-120s (timeout) |
| API process crash | Immediate | 5-30s (reconnect) |
| Network partition | 9-40s (BFD: 300ms) | 30-120s |
| Node restart | ~10s (pod startup) | ~10s (service ready) |

## Recommendation

### Choose MetalLB FRR BGP if:

- Fast failover (<3s) is important
- Running production or production-like workloads
- Already comfortable with BGP and Calico
- Want network-level load balancing

### Choose DNS Round-Robin if:

- Simplicity is the priority
- Can tolerate 30-60 second failover
- Testing/development environment
- Want minimal additional components

---

## Quick Reference

### Network Allocation

```
Full /64:              2001:a61:1162:79fb::/64
├── Host network:      2001:a61:1162:79fb:0000-ffcb::  (RA advertised)
├── Pod CIDR:          2001:a61:1162:79fb:ffcc::/112   (Calico IPAM)
├── ClusterIP CIDR:    2001:a61:1162:79fb:ff00::/112   (k3s services)
│   └── Cluster DNS:   2001:a61:1162:79fb:ff00::10
└── LoadBalancer CIDR: 2001:a61:1162:79fb:ff01::/112   (MetalLB pool)
```

### DNS Names

| Name | Purpose | Type |
|------|---------|------|
| k8s-node01.k8s.lzadm.com | Individual node | AAAA |
| k8s-node02.k8s.lzadm.com | Individual node | AAAA |
| k8s-node03.k8s.lzadm.com | Individual node | AAAA |
| k8s-cluster.k8s.lzadm.com | Round-robin all nodes | AAAA (×3) |
| k8s-api.k8s.lzadm.com | MetalLB LoadBalancer VIP | AAAA (ff01::x) |

### AS Numbers

| Device | AS Number |
|--------|-----------|
| pfSense FRR | 65101 |
| Calico/k3s | 65010 |

---

## Appendix: Complete MetalLB + Calico Integration

This section provides the complete, copy-paste ready configuration for integrating MetalLB with Calico BGP. MetalLB handles IP allocation only (controller), while Calico handles all BGP advertisement to pfSense.

### Current Environment

```
Network:           2001:a61:1162:79fb::/64
Pod CIDR:          2001:a61:1162:79fb:ffcc::/112
Service CIDR:      2001:a61:1162:79fb:ff00::/112  (ClusterIP)
LoadBalancer CIDR: 2001:a61:1162:79fb:ff01::/112  (MetalLB pool)
Calico AS:         65010
pfSense AS:        65101
```

### Architecture After Integration

```
┌────────────────────────────────────────────────────────────────┐
│                    pfSense (AS 65101)                          │
│                                                                │
│  BGP Routes from Calico (after pfsense-export-filter):         │
│  ├── 2001:a61:1162:79fb:ff00::/112  (ClusterIP services)      │
│  └── 2001:a61:1162:79fb:ff01::/112  (LoadBalancer IPs)        │
│                                                                │
│  FILTERED OUT (rejected by pfsense-export-filter):             │
│  └── 2001:a61:1162:79fb:ffcc::/120  (pod routes)              │
└────────────────────────────────────────────────────────────────┘
                          │
                          │ BGP (external peer only)
                          │ + pfsense-export-filter
                          │ Node-to-node mesh DISABLED
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
        ▼                 ▼                 ▼
  ┌───────────┐    ┌───────────┐    ┌───────────┐
  │k8s-node01 │    │k8s-node02 │    │k8s-node03 │
  │           │    │           │    │           │
  │ Calico    │    │ Calico    │    │ Calico    │
  │ (AS 65010)│    │ (AS 65010)│    │ (AS 65010)│
  │           │    │           │    │           │
  │ BGPFilters│    │ BGPFilters│    │ BGPFilters│
  │           │    │           │    │           │
  │ MetalLB   │    │ MetalLB   │    │ MetalLB   │
  │(controller)│   │    ---    │    │    ---    │
  │           │    │           │    │           │
  │ API :6443 │    │ API :6443 │    │ API :6443 │
  └───────────┘    └───────────┘    └───────────┘
```

**Key Points:**
- MetalLB runs **controller only** (no speaker) - handles IP allocation from pool
- Calico handles **all BGP advertisement** to pfSense
- **Node-to-node mesh disabled** - only external BGP peer to pfSense
- **pfsense-export-filter** - rejects pod CIDR to pfSense, accepts service/LB CIDRs
- **internal-lb-filter** - rejects LB CIDR from internal node-to-node routes
- **externalTrafficPolicy: Local** preserves source IP

### Step 1: Install MetalLB Controller Only (v0.15.3)

```bash
# Install MetalLB native manifest (latest v0.15.3)
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml

# Wait for controller to be ready
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=component=controller \
  --timeout=120s

# Remove the speaker DaemonSet - Calico handles BGP
kubectl delete daemonset speaker -n metallb-system

# Verify only controller is running
kubectl get pods -n metallb-system
# Should show: controller-xxx only, no speaker pods
```

### Step 2: Create LoadBalancer IP Address Pool

```yaml
# metallb-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: loadbalancer-pool
  namespace: metallb-system
spec:
  addresses:
  # Dedicated /112 subnet for LoadBalancer IPs
  # Separate from ClusterIP service CIDR (ff00::/112)
  - "2001:a61:1162:79fb:ff01::/112"
  autoAssign: true
```

Apply:
```bash
kubectl apply -f metallb-pool.yaml
```

**Note:** No L2Advertisement or BGPAdvertisement needed - Calico handles BGP.

### Step 3: Update Calico BGPConfiguration

Disable node-to-node mesh and configure LoadBalancer IP advertisement:

```yaml
# calico-bgp-config.yaml
apiVersion: projectcalico.org/v3
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: 65010
  logSeverityScreen: Info
  # IMPORTANT: Disable node-to-node mesh
  # All routing goes through pfSense as route reflector
  nodeToNodeMeshEnabled: false
  # Advertise ClusterIP services
  serviceClusterIPs:
  - cidr: 2001:a61:1162:79fb:ff00::/112
  # Advertise LoadBalancer IPs (MetalLB pool)
  serviceLoadBalancerIPs:
  - cidr: 2001:a61:1162:79fb:ff01::/112
```

Apply:
```bash
kubectl apply -f calico-bgp-config.yaml
```

### Step 4: Create BGPFilters

BGPFilter resources control which routes are imported/exported between BGP peers. Rules are evaluated sequentially - the first matching rule's action is taken. Default action is **Accept** if no rules match.

#### 4a. Filter for pfSense (External Peer)

Reject pod CIDR from being advertised to pfSense, allow everything else (services, LoadBalancer IPs):

```yaml
# calico-bgp-filter-pfsense.yaml
apiVersion: projectcalico.org/v3
kind: BGPFilter
metadata:
  name: pfsense-export-filter
spec:
  exportV6:
    # Reject pod CIDR advertisements to pfSense
    - action: Reject
      matchOperator: In
      cidr: 2001:a61:1162:79fb:ffcc::/112
    # Default action is Accept - ClusterIP and LoadBalancer CIDRs pass through
```

Apply:
```bash
calicoctl apply -f calico-bgp-filter-pfsense.yaml
```

#### 4b. Filter for Internal BGP (Node-to-Node)

Block LoadBalancer CIDR from being advertised between cluster nodes:

```yaml
# calico-bgp-filter-internal.yaml
apiVersion: projectcalico.org/v3
kind: BGPFilter
metadata:
  name: internal-lb-filter
spec:
  exportV6:
    # Reject LoadBalancer CIDR from internal node-to-node advertisements
    - action: Reject
      matchOperator: In
      cidr: 2001:a61:1162:79fb:ff01::/112
    # Default action is Accept - pod routes pass through
```

Apply:
```bash
calicoctl apply -f calico-bgp-filter-internal.yaml
```

#### 4c. Apply Filter to Internal BGP Peers

**Important:** BGPFilters can only be applied to explicit BGPPeer resources via the `filters` field. The automatic node-to-node mesh does not support filters.

To apply filters to internal BGP:
1. Disable the automatic node-to-node mesh (done in Step 3)
2. Create explicit BGPPeer with `nodeSelector` + `peerSelector`
3. Attach filters to the BGPPeer

```yaml
# calico-bgp-peer-internal.yaml
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata:
  name: internal-node-mesh
spec:
  # All nodes participate
  nodeSelector: all()
  # Peer with all other nodes
  peerSelector: all()
  # Apply the internal filter
  filters:
    - internal-lb-filter
```

Apply:
```bash
calicoctl apply -f calico-bgp-peer-internal.yaml
```

**Note:** With `nodeToNodeMeshEnabled: false` and pfSense as the only external peer, internal node peering may not be needed if pfSense acts as a route reflector. Only create this peer if you need direct node-to-node BGP sessions.

### Step 5: Configure BGP Peer to pfSense (with filter)

Update the BGP peer to pfSense with the export filter attached:

```yaml
# calico-bgp-peer-pfsense.yaml
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
```

Apply:
```bash
calicoctl apply -f calico-bgp-peer-pfsense.yaml
```

**Routes advertised to pfSense after filter:**
- ClusterIP CIDR: `2001:a61:1162:79fb:ff00::/112` (Accepted)
- LoadBalancer CIDR: `2001:a61:1162:79fb:ff01::/112` (Accepted)
- Pod CIDR: `2001:a61:1162:79fb:ffcc::/112` (Rejected by filter)

### Step 6: Update k3s TLS SAN

On **each server node**, update `/etc/rancher/k3s/config.yaml`:

```yaml
# Add to existing config.yaml
tls-san:
  - "k8s-node01"
  - "k8s-node02"
  - "k8s-node03"
  - "k8s-cluster.k8s.lzadm.com"
  - "2001:a61:1162:79fb:ff01::1"  # Example API VIP from new pool
```

Then restart k3s on each server:
```bash
systemctl restart k3s
```

### Step 7: Create LoadBalancer Service (externalTrafficPolicy: Local)

```yaml
# api-loadbalancer.yaml
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-api-vip
  namespace: default
  annotations:
    metallb.universe.tf/address-pool: loadbalancer-pool
spec:
  type: LoadBalancer
  # IMPORTANT: Local preserves source IP, traffic only to nodes with pods
  externalTrafficPolicy: Local
  ipFamilies:
  - IPv6
  ipFamilyPolicy: SingleStack
  ports:
  - name: https
    port: 6443
    targetPort: 6443
    protocol: TCP
  selector:
    # For API server, you may need EndpointSlice approach
    # or point to a deployment that proxies to API
```

**externalTrafficPolicy Comparison:**

| Policy | Source IP | Load Distribution | Extra Hops |
|--------|-----------|-------------------|------------|
| Cluster | Masked (SNAT) | Even across all pods | Possible |
| Local | Preserved | Only nodes with pods | None |

**Recommendation:** Use `Local` for source IP preservation and direct routing.

### Step 8: Add DNS Entry for VIP

Using nsupdate:
```bash
nsupdate -p 5353 << EOF
server <pfsense-ipv6>
zone k8s.lzadm.com
update add k8s-api.k8s.lzadm.com. 300 AAAA 2001:a61:1162:79fb:ff01::1
send
EOF
```

Or add to BIND9 zone file:
```
k8s-api.k8s.lzadm.com.  300  IN  AAAA  2001:a61:1162:79fb:ff01::1
```

### Step 9: Update kubeconfig

```yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: <existing-ca-data>
    server: https://[2001:a61:1162:79fb:ff01::1]:6443
    # OR: https://k8s-api.k8s.lzadm.com:6443
  name: k3s-ha
contexts:
- context:
    cluster: k3s-ha
    user: default
  name: k3s-ha
current-context: k3s-ha
users:
- name: default
  user:
    client-certificate-data: <existing-cert-data>
    client-key-data: <existing-key-data>
```

### Verification Commands

```bash
# 1. Check MetalLB controller only (no speaker)
kubectl get pods -n metallb-system
# Expected: controller-xxx Running, NO speaker pods

# 2. Check IP address pool
kubectl get ipaddresspools -n metallb-system -o yaml

# 3. Check LoadBalancer service got an IP
kubectl get svc kubernetes-api-vip -o wide
# Should show EXTERNAL-IP from ff01::/112 range

# 4. Check Calico BGP config
calicoctl get bgpconfiguration default -o yaml
# Verify: nodeToNodeMeshEnabled: false, serviceLoadBalancerIPs set

# 5. Check BGP filters
calicoctl get bgpfilter -o wide
calicoctl get bgpfilter pfsense-export-filter -o yaml
calicoctl get bgpfilter internal-lb-filter -o yaml

# 6. Check BGP peer status
calicoctl node status
# Should show: pfSense peer Established, no node-to-node peers

# 7. On pfSense - verify BGP routes in FRR shell:
show bgp ipv6 unicast
# Should see (after BGPFilter applied):
#   2001:a61:1162:79fb:ff00::/112 (ClusterIP services)
#   2001:a61:1162:79fb:ff01::/112 (LoadBalancer IPs)
# Should NOT see (filtered by pfsense-export-filter):
#   2001:a61:1162:79fb:ffcc::/120 (pod routes - rejected)

# 8. Test LoadBalancer IP connectivity
curl -k https://[2001:a61:1162:79fb:ff01::1]:6443/healthz

# 9. Test with kubectl
kubectl --server=https://[2001:a61:1162:79fb:ff01::1]:6443 get nodes
```

### Troubleshooting

**MetalLB controller not assigning IPs:**
```bash
kubectl describe svc <service-name>
kubectl logs -n metallb-system -l component=controller
kubectl get events -n metallb-system
```

**BGP routes not appearing on pfSense:**
```bash
# Check Calico node BGP status
calicoctl node status

# Check BGP peer is established
calicoctl get bgppeer -o wide

# Check service has LoadBalancer IP assigned
kubectl get svc -A -o wide | grep LoadBalancer

# Verify serviceLoadBalancerIPs in BGPConfiguration
calicoctl get bgpconfiguration default -o yaml | grep -A3 serviceLoadBalancerIPs
```

**Node-to-node routing broken after disabling mesh:**
```bash
# Verify pfSense is advertising routes back to nodes
# On a k8s node:
ip -6 route | grep ff

# Check pfSense FRR is redistributing routes
# In pfSense FRR shell:
show ipv6 route bgp
```

**LoadBalancer service stuck in Pending:**
```bash
# Check MetalLB controller logs
kubectl logs -n metallb-system -l component=controller

# Verify IPAddressPool has available addresses
kubectl get ipaddresspools -n metallb-system -o yaml

# Check service annotations
kubectl get svc <name> -o yaml | grep -A5 annotations
```

**Certificate errors when connecting to VIP:**
```bash
# Verify VIP is in certificate SANs
openssl s_client -connect [2001:a61:1162:79fb:ff01::1]:6443 </dev/null 2>/dev/null | \
  openssl x509 -noout -text | grep -A1 "Subject Alternative Name"

# If VIP missing, update config.yaml and restart k3s
systemctl restart k3s
```

### Network Allocation Summary

```
Full /64:              2001:a61:1162:79fb::/64
├── Host network:      2001:a61:1162:79fb:0000-ffcb::  (RA advertised)
├── Pod CIDR:          2001:a61:1162:79fb:ffcc::/112   (Calico IPAM)
├── ClusterIP CIDR:    2001:a61:1162:79fb:ff00::/112   (k3s services)
│   └── Cluster DNS:   2001:a61:1162:79fb:ff00::10
└── LoadBalancer CIDR: 2001:a61:1162:79fb:ff01::/112   (MetalLB pool) ← NEW
```

### Component Responsibilities

| Component | Responsibility |
|-----------|----------------|
| MetalLB Controller | IP allocation from pool to LoadBalancer services |
| Calico | BGP peering with pfSense, route advertisement |
| BGPFilter: pfsense-export-filter | Block Pod CIDR from pfSense advertisements |
| BGPFilter: internal-lb-filter | Block LB CIDR from internal node-to-node routes |
| pfSense FRR | External BGP peer, route distribution |
| k3s | API server, service management |

### BGPFilter Reference

| Filter Name | Applied To | Action | CIDR |
|-------------|------------|--------|------|
| pfsense-export-filter | BGPPeer: pfsense | Reject export | ffcc::/112 (pods) |
| internal-lb-filter | BGPPeer: internal-node-mesh | Reject export | ff01::/112 (LB) |

**BGPFilter Rule Evaluation:**
1. Rules are evaluated sequentially (top to bottom)
2. First matching rule's action is taken
3. Default action is **Accept** if no rules match
4. Use `matchOperator: In` for CIDR containment matching
