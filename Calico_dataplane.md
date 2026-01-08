# Calico Dataplane Comparison: iptables vs eBPF

This document compares Calico's iptables and eBPF dataplanes in the context of an IPv6-only home lab Kubernetes environment.

## Environment Context

- **Cluster**: k3s multi-node on Debian 13 (kernel 6.12)
- **Network**: IPv6-only with DNS64/NAT64
- **CNI**: Calico 3.31.3 with BGP peering to pfSense
- **Routing**: Native/direct routing (no encapsulation)
- **Scale**: Home lab (~10-50 services)

## Current Setup

**Decision**: Stay with iptables dataplane + BGP direct routing

This combination provides:
- Simple, well-understood architecture
- Direct BGP route advertisement to pfSense
- Real pod IPs visible on home network
- No encapsulation overhead
- Mature IPv6 support

## Dataplane Architecture Comparison

### iptables Dataplane (Current)

```
Packet arrives
      │
      ▼
┌─────────────────────────────────────────────────────────────┐
│                    PREROUTING chain                          │
│  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐               │
│  │Rule1│─▶│Rule2│─▶│Rule3│─▶│Rule4│─▶│Rule5│─▶ ... ─▶ RuleN │
│  └─────┘  └─────┘  └─────┘  └─────┘  └─────┘               │
│            (linear scan through all rules)                   │
└─────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────┐
│                    FORWARD chain                             │
│  (same linear scanning pattern)                              │
└─────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────┐
│                   POSTROUTING chain                          │
│  (same linear scanning pattern)                              │
└─────────────────────────────────────────────────────────────┘
      │
      ▼
Packet delivered
```

**How it works:**
1. Uses Linux netfilter framework
2. Rules evaluated sequentially in each chain
3. First matching rule determines action
4. More services = more rules = longer evaluation
5. Complexity: **O(n)** where n = number of rules

### eBPF Dataplane

```
Packet arrives
      │
      ▼
┌─────────────────────────────────────────────────────────────┐
│                    eBPF Program                              │
│                                                              │
│   ┌──────────────────────────────────────────────┐          │
│   │          Hash Table Lookup                    │          │
│   │  ┌─────────────────────────────────────────┐ │          │
│   │  │ Key: dst_ip:port                        │ │          │
│   │  │ Value: backend_pod_ip:port              │ │          │
│   │  └─────────────────────────────────────────┘ │          │
│   │              │                               │          │
│   │              ▼                               │          │
│   │     Direct O(1) lookup                       │          │
│   └──────────────────────────────────────────────┘          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
      │
      ▼
Packet delivered (bypasses netfilter)
```

**How it works:**
1. Runs sandboxed programs in kernel
2. Hash table lookup for routing decisions
3. Constant time regardless of service count
4. Bypasses iptables chains entirely
5. Complexity: **O(1)** constant time

## Performance Benchmarks

### Service Routing Latency

| Services | iptables Latency | eBPF Latency | iptables Overhead |
|----------|------------------|--------------|-------------------|
| 1 | 575 µs | ~550 µs | ~same |
| 100 | ~580 µs | ~550 µs | +5% |
| 1,000 | 614-631 µs | ~550 µs | +12% |
| 5,000 | ~750 µs | ~550 µs | +36% |
| 10,000 | 1,023-1,050 µs | ~550 µs | +90% |
| 25,000 | 1,400-3,000 µs | ~550 µs | +155-445% |
| 50,000 | 1,821-7,077 µs | ~550 µs | +230-1187% |

**Note**: iptables shows range because first service in chain is faster than last.

### Rule Update Times

| Services | iptables Update | eBPF Update |
|----------|-----------------|-------------|
| 1,000 | ~2 minutes | milliseconds |
| 5,000 | ~11 minutes | milliseconds |
| 10,000 | ~30+ minutes | milliseconds |

### Memory Usage

| Scale | iptables | eBPF |
|-------|----------|------|
| Base overhead | Lower | Higher (~10-20MB) |
| Per-service | Higher (rules) | Lower (hash entries) |
| At 10,000 services | Similar | Similar |
| At 50,000 services | Higher | Lower |

## Independent Choices: Dataplane vs Encapsulation

**Important**: Dataplane (iptables/eBPF) and encapsulation (None/VXLAN) are independent choices.

| Dataplane | Encapsulation | Valid? | Use Case |
|-----------|---------------|--------|----------|
| iptables | None | Yes | **Current setup** - BGP routing |
| iptables | VXLAN | Yes | Overlay without eBPF |
| eBPF | None | Yes | High-perf BGP routing |
| eBPF | VXLAN | Yes | High-perf overlay |

All four combinations are valid. The choice depends on:
- **Dataplane**: Scale and performance requirements
- **Encapsulation**: Network topology and routing capabilities

## Why iptables is Right for Home Lab

| Factor | Assessment |
|--------|------------|
| Scale (~10-50 services) | iptables handles easily |
| Latency impact | <5% overhead at this scale |
| Rule updates | Seconds, not minutes |
| Debugging | iptables -L is familiar |
| IPv6 maturity | iptables IPv6 very mature |
| Kernel requirements | Works on any kernel |
| Complexity | Simpler to troubleshoot |
| BGP integration | Works perfectly |

## When to Consider eBPF

Reconsider eBPF if any of these become true:

1. **Scale**: Growing beyond 1,000 services
2. **Latency**: Need consistent sub-millisecond latency
3. **Updates**: Frequent service changes cause visible delays
4. **Features**: Need eBPF-specific features:
   - Native host endpoint protection
   - DSR (Direct Server Return)
   - XDP acceleration
5. **Workloads**: Running latency-sensitive applications

## eBPF Configuration Reference

If migrating to eBPF in the future, here's the configuration:

### Prerequisites

1. Kernel 5.3+ (5.8+ recommended) - Debian 13 has 6.12 ✓
2. Calico 3.13+ for eBPF, 3.27+ for IPv6 eBPF ✓
3. k3s must be installed with `--disable-kube-proxy`

### API Server ConfigMap

Required because eBPF replaces kube-proxy:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubernetes-services-endpoint
  namespace: tigera-operator
data:
  KUBERNETES_SERVICE_HOST: "k8s-node01.k8s.lzadm.com"
  KUBERNETES_SERVICE_PORT: "6443"
```

### Installation with eBPF

```yaml
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    linuxDataplane: BPF              # Enable eBPF
    ipPools:
      - blockSize: 120
        cidr: 2001:a61:1162:79fb:ffcc::/112
        encapsulation: None          # Keep native routing
        natOutgoing: Disabled
        nodeSelector: all()
    nodeAddressAutodetectionV6:
      kubernetes: NodeInternalIP
```

### Migration Steps

1. Create API Server ConfigMap
2. Reinstall k3s with `--disable-kube-proxy`
3. Update Calico Installation to use `linuxDataplane: BPF`
4. Verify BGP peering still works
5. Test service connectivity

## Summary

For an IPv6-only home lab with ~10-50 services:

| Aspect | Recommendation |
|--------|----------------|
| Dataplane | **iptables** (current) |
| Encapsulation | **None** (native routing) |
| Routing | **BGP** to pfSense |
| Reasoning | Scale doesn't justify eBPF complexity |

The current setup with iptables + BGP direct routing is optimal for this environment. eBPF provides no meaningful benefit at home lab scale while adding operational complexity.
