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
│  BGP Routes Learned:                                        │
│  - 2001:a61:1162:79fb:ffcc::/112  (pod network - Calico)   │
│  - 2001:a61:1162:79fb:ff00::/112  (svc network - Calico)   │
│  - 2001:a61:1162:79fb:ff00::100   (API VIP - Calico)       │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ BGP (AS 65010)
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
        ▼                 ▼                 ▼
  ┌───────────┐    ┌───────────┐    ┌───────────┐
  │k8s-node01 │    │k8s-node02 │    │k8s-node03 │
  │           │    │           │    │           │
  │ Calico    │    │ Calico    │    │ Calico    │
  │ Speaker   │    │ Speaker   │    │ Speaker   │
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

#### 4. Create L2 Advertisement (for local network)

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

#### 5. Update k3s TLS SAN

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

#### 6. Create LoadBalancer Service for API Server

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

#### 7. Add DNS Entry for VIP

Add to pfSense BIND9 zone:

```
k8s-api.k8s.lzadm.com.  300  IN  AAAA  2001:a61:1162:79fb:ff00::100
```

#### 8. Update kubeconfig

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

# Check BGP routes on pfSense
# In pfSense FRR shell:
show bgp ipv6 unicast

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

### MetalLB VIP Allocation

```
Full /64:        2001:a61:1162:79fb::/64
├── Host network: 2001:a61:1162:79fb:0000-ffcb::
├── Pod CIDR:     2001:a61:1162:79fb:ffcc::/112
├── Service CIDR: 2001:a61:1162:79fb:ff00::/112
└── API VIP:      2001:a61:1162:79fb:ff00::100/128  ← MetalLB
```

### DNS Names

| Name | Purpose | Type |
|------|---------|------|
| k8s-node01.k8s.lzadm.com | Individual node | AAAA |
| k8s-node02.k8s.lzadm.com | Individual node | AAAA |
| k8s-node03.k8s.lzadm.com | Individual node | AAAA |
| k8s-cluster.k8s.lzadm.com | Round-robin all nodes | AAAA (×3) |
| k8s-api.k8s.lzadm.com | MetalLB VIP | AAAA |

### AS Numbers

| Device | AS Number |
|--------|-----------|
| pfSense FRR | 65101 |
| Calico/k3s | 65010 |

---

## Appendix: Complete MetalLB + Calico Integration

This section provides the complete, copy-paste ready configuration for integrating MetalLB with the existing Calico BGP setup.

### Current Environment

```
Network:      2001:a61:1162:79fb::/64
Pod CIDR:     2001:a61:1162:79fb:ffcc::/112
Service CIDR: 2001:a61:1162:79fb:ff00::/112
Calico AS:    65010
pfSense AS:   65101
API VIP:      2001:a61:1162:79fb:ff00::100
```

### Architecture After Integration

```
┌────────────────────────────────────────────────────────────────┐
│                    pfSense (AS 65101)                          │
│                                                                │
│  BGP Routes from Calico:                                       │
│  ├── 2001:a61:1162:79fb:ffcc::/120  (node01 pods)             │
│  ├── 2001:a61:1162:79fb:ffcc::/120  (node02 pods)             │
│  ├── 2001:a61:1162:79fb:ff00::/112  (service CIDR)            │
│  └── 2001:a61:1162:79fb:ff00::100   (API VIP) ← NEW           │
└────────────────────────────────────────────────────────────────┘
                          │
                          │ Single BGP session per node
                          │ (Calico handles everything)
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
  │ MetalLB   │    │ MetalLB   │    │ MetalLB   │
  │ (L2 mode) │    │ (L2 mode) │    │ (L2 mode) │
  │           │    │           │    │           │
  │ API :6443 │    │ API :6443 │    │ API :6443 │
  └───────────┘    └───────────┘    └───────────┘
```

**Key:** MetalLB runs in L2 mode for IP assignment, Calico advertises the VIP via BGP. No BGP conflicts because only Calico peers with pfSense.

### Step 1: Install MetalLB (FRR Mode for IPv6)

```bash
# Install MetalLB with FRR backend
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-frr.yaml

# Wait for controller to be ready
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=component=controller \
  --timeout=120s
```

### Step 2: Create API VIP Address Pool

```yaml
# metallb-api-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: api-vip-pool
  namespace: metallb-system
spec:
  addresses:
  # Use an IP from service CIDR range for API VIP
  # Choosing ::100 to avoid conflicts with cluster DNS (::10)
  - "2001:a61:1162:79fb:ff00::100/128"
  autoAssign: false
---
# L2 Advertisement for local subnet
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: api-vip-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - api-vip-pool
```

Apply:
```bash
kubectl apply -f metallb-api-pool.yaml
```

### Step 3: Update Calico BGPConfiguration

This is the key integration step - Calico advertises the MetalLB VIP via BGP:

```yaml
# calico-bgp-config-updated.yaml
apiVersion: projectcalico.org/v3
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: 65010
  # Existing: advertise ClusterIP services
  serviceClusterIPs:
  - cidr: 2001:a61:1162:79fb:ff00::/112
  # NEW: advertise MetalLB LoadBalancer IPs
  serviceExternalIPs:
  - cidr: 2001:a61:1162:79fb:ff00::100/128
  # Optional: advertise all LoadBalancer services automatically
  serviceLoadBalancerIPs:
  - cidr: 2001:a61:1162:79fb:ff00::/112
```

Apply:
```bash
kubectl apply -f calico-bgp-config-updated.yaml
```

### Step 4: Verify Existing BGP Peer (No Changes Needed)

Your existing BGP peer configuration remains unchanged:

```yaml
# Existing - no changes needed
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
```

### Step 5: Update k3s TLS SAN

On **each server node**, update `/etc/rancher/k3s/config.yaml`:

```yaml
# Add to existing config.yaml
tls-san:
  - "k8s-node01"
  - "k8s-node02"
  - "k8s-node03"
  - "k8s-cluster.k8s.lzadm.com"
  - "2001:a61:1162:79fb:ff00::100"  # MetalLB VIP
```

Then restart k3s on each server:
```bash
systemctl restart k3s
```

### Step 6: Create API LoadBalancer Service

Option A - Simple LoadBalancer (if you have an endpoint controller):

```yaml
# api-loadbalancer-simple.yaml
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-api-vip
  namespace: default
  annotations:
    metallb.universe.tf/address-pool: api-vip-pool
    metallb.universe.tf/loadBalancerIPs: "2001:a61:1162:79fb:ff00::100"
spec:
  type: LoadBalancer
  loadBalancerIP: "2001:a61:1162:79fb:ff00::100"
  ipFamilies:
  - IPv6
  ipFamilyPolicy: SingleStack
  ports:
  - name: https
    port: 6443
    targetPort: 6443
    protocol: TCP
  selector:
    # Empty - endpoints managed separately
```

Option B - With EndpointSlice (explicit node endpoints):

```yaml
# api-loadbalancer-endpoints.yaml
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-api-vip
  namespace: default
  annotations:
    metallb.universe.tf/address-pool: api-vip-pool
spec:
  type: LoadBalancer
  loadBalancerIP: "2001:a61:1162:79fb:ff00::100"
  ipFamilies:
  - IPv6
  ipFamilyPolicy: SingleStack
  ports:
  - name: https
    port: 6443
    targetPort: 6443
    protocol: TCP
  clusterIP: None  # Headless
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: kubernetes-api-vip-endpoints
  namespace: default
  labels:
    kubernetes.io/service-name: kubernetes-api-vip
addressType: IPv6
ports:
- name: https
  port: 6443
  protocol: TCP
endpoints:
- addresses:
  - "2001:a61:1162:79fb:xxxx:xxxx:xxxx:1"  # k8s-node01 IPv6
  conditions:
    ready: true
- addresses:
  - "2001:a61:1162:79fb:xxxx:xxxx:xxxx:2"  # k8s-node02 IPv6
  conditions:
    ready: true
- addresses:
  - "2001:a61:1162:79fb:xxxx:xxxx:xxxx:3"  # k8s-node03 IPv6
  conditions:
    ready: true
```

**Note:** Replace `xxxx:xxxx:xxxx:1`, etc. with actual node IPv6 addresses.

### Step 7: Add DNS Entry for VIP

Using nsupdate:
```bash
nsupdate -p 5353 << EOF
server <pfsense-ipv6>
zone k8s.lzadm.com
update add k8s-api.k8s.lzadm.com. 300 AAAA 2001:a61:1162:79fb:ff00::100
send
EOF
```

Or add to BIND9 zone file:
```
k8s-api.k8s.lzadm.com.  300  IN  AAAA  2001:a61:1162:79fb:ff00::100
```

### Step 8: Update kubeconfig

```yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: <existing-ca-data>
    server: https://[2001:a61:1162:79fb:ff00::100]:6443
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
# 1. Check MetalLB pods
kubectl get pods -n metallb-system

# 2. Check IP address pool
kubectl get ipaddresspools -n metallb-system

# 3. Check service got the VIP
kubectl get svc kubernetes-api-vip -o wide

# 4. Check Calico BGP config includes serviceExternalIPs
kubectl get bgpconfiguration default -o yaml

# 5. Check BGP routes advertised (on a node)
sudo calicoctl node status

# 6. On pfSense - verify BGP routes
# In FRR shell:
show bgp ipv6 unicast
# Should see: 2001:a61:1162:79fb:ff00::100/128

# 7. Test VIP connectivity
curl -k https://[2001:a61:1162:79fb:ff00::100]:6443/healthz

# 8. Test with kubectl
kubectl --server=https://[2001:a61:1162:79fb:ff00::100]:6443 get nodes
```

### Troubleshooting

**MetalLB pods not running:**
```bash
kubectl describe pods -n metallb-system
kubectl logs -n metallb-system -l component=controller
```

**VIP not assigned to service:**
```bash
kubectl describe svc kubernetes-api-vip
kubectl get events -n metallb-system
```

**BGP route not appearing on pfSense:**
```bash
# Check Calico is advertising
sudo calicoctl node status

# Check BGP peer status
kubectl get bgppeer -o yaml

# Check BGPConfiguration has serviceExternalIPs
kubectl get bgpconfiguration default -o yaml | grep -A5 serviceExternalIPs
```

**Certificate errors when connecting to VIP:**
```bash
# Verify VIP is in certificate SANs
openssl s_client -connect [2001:a61:1162:79fb:ff00::100]:6443 </dev/null 2>/dev/null | \
  openssl x509 -noout -text | grep -A1 "Subject Alternative Name"

# If VIP missing, restart k3s after updating config.yaml
systemctl restart k3s
```
