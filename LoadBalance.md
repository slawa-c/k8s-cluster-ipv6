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
