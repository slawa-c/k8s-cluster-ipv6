# Kubernetes API LoadBalancer Setup

This guide configures the Kubernetes API server with a LoadBalancer service for reliable, resilient cluster management access.

## Overview

By default, k3s exposes the API server only via ClusterIP. Using a LoadBalancer provides:
- **High Availability:** Automatic failover between server nodes
- **Stable VIP:** Single IP address survives node failures
- **DNS Integration:** Single hostname via ExternalDNS
- **BGP Advertisement:** Announced to home network via MetalLB

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Management Access                                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  [kubectl]                                                       │
│       │                                                          │
│       │ → api.k8s.lzadm.com (DNS)                               │
│       ▼                                                          │
│  pfSense BIND → 2001:a61:1162:79fb:ff01::1                      │
│       │                                                          │
│       │ (BGP route from MetalLB)                                │
│       ▼                                                          │
│  MetalLB LoadBalancer (ff01::1)                                 │
│       │                                                          │
│       ├──▶ k8s-node01:6443 (server 1)                           │
│       ├──▶ k8s-node02:6443 (server 2)                           │
│       └──▶ k8s-node03:6443 (server 3)                           │
│                                                                  │
│  Automatic failover if any node fails!                          │
└─────────────────────────────────────────────────────────────────┘
```

**IP Allocation:**
- ClusterIP: `2001:a61:1162:79fb:ff00::1` (internal only)
- LoadBalancer IP: `2001:a61:1162:79fb:ff01::1` (BGP advertised)
- DNS Name: `api.k8s.lzadm.com`

## Initial Setup

### Step 1: Convert kubernetes Service to LoadBalancer

```bash
# Patch the default kubernetes service
kubectl patch svc kubernetes -p '{"spec":{"type":"LoadBalancer","loadBalancerIP":"2001:a61:1162:79fb:ff01::1"}}'

# Add ExternalDNS annotation for automatic DNS record
kubectl annotate svc kubernetes external-dns.alpha.kubernetes.io/hostname=api.k8s.lzadm.com

# Verify
kubectl get svc kubernetes -o wide
```

**Expected output:**
```
NAME         TYPE           CLUSTER-IP              EXTERNAL-IP                  PORT(S)
kubernetes   LoadBalancer   2001:...:ff00::1        2001:...:ff01::1             443:xxxxx/TCP
```

### Step 2: Verify BGP and DNS

```bash
# Check MetalLB assigned the IP
kubectl get svc kubernetes -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# Should output: 2001:a61:1162:79fb:ff01::1

# Wait for ExternalDNS to create DNS record (1-2 minutes)
kubectl logs -n external-dns -l app=external-dns --tail=10

# Query DNS
dig @2001:a61:1162:79fb:2e0:4cff:fe68:9ff -p 5353 api.k8s.lzadm.com AAAA +short
# Should output: 2001:a61:1162:79fb:ff01::1
```

### Step 3: Update TLS Certificate

The k3s API server certificate must include the LoadBalancer IP and DNS name.

**On each k3s server node** (k8s-node01, k8s-node02, k8s-node03):

```bash
# SSH to server node
ssh k8s-node01

# Backup current config
sudo cp /etc/rancher/k3s/config.yaml /etc/rancher/k3s/config.yaml.backup

# Edit config
sudo nano /etc/rancher/k3s/config.yaml
```

**Add to `tls-san` section:**
```yaml
tls-san:
  - "ctrl.k8s.lzadm.com"
  - "k3s-cluster.k8s.lzadm.com"
  - "api.k8s.lzadm.com"                      # ADD THIS
  - "2001:a61:1162:79fb:ff01::1"             # ADD THIS
```

**Save and restart k3s:**
```bash
sudo systemctl restart k3s

# Verify
sudo systemctl status k3s
```

**Repeat for all server nodes.**

### Step 4: Test API Access

```bash
# Test via DNS name
kubectl get nodes --server=https://api.k8s.lzadm.com:443

# Test via LoadBalancer IP
kubectl get nodes --server=https://[2001:a61:1162:79fb:ff01::1]:443

# Verify certificate includes new SANs
openssl s_client -connect api.k8s.lzadm.com:443 </dev/null 2>/dev/null | \
  openssl x509 -noout -text | grep -A2 "Subject Alternative Name"
```

---

## Permanent Solution: Auto-Apply Manifest

### Problem

**After k3s restart, the kubernetes service reverts to ClusterIP type.**

This is because k3s recreates the default `kubernetes` service on startup and always sets it to `ClusterIP`. Manual patches are lost.

### Root Cause

From k3s source code:
```go
// k3s automatically creates the "kubernetes" service in the "default" namespace
// and always sets type: ClusterIP
```

When k3s restarts:
1. Service is recreated as ClusterIP
2. `loadBalancerIP` field is preserved but ignored (not a LoadBalancer)
3. ExternalDNS detects the change and removes the DNS record
4. LoadBalancer IP is released back to MetalLB pool

### Solution: k3s Auto-Apply Manifests

k3s automatically applies manifests from `/var/lib/rancher/k3s/server/manifests/` on every startup.

**On each k3s server node**, create the manifest:

```bash
# SSH to server node
ssh k8s-node01

# Create the auto-apply manifest
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

# Verify the manifest was created
ls -la /var/lib/rancher/k3s/server/manifests/
cat /var/lib/rancher/k3s/server/manifests/kubernetes-api-loadbalancer.yaml
```

**How it works:**
- k3s watches the manifests directory
- Any YAML files are automatically applied on startup
- Manifests are reconciled continuously
- Changes to manifests are automatically applied
- Service will always be LoadBalancer type after restart

**Repeat on all server nodes:** k8s-node02, k8s-node03

### Verification

Test the permanent fix by restarting k3s:

```bash
# On a server node
sudo systemctl restart k3s

# Wait 30 seconds for k3s to start

# From management machine, verify service is still LoadBalancer
kubectl get svc kubernetes -o wide

# Expected output:
# TYPE           EXTERNAL-IP
# LoadBalancer   2001:a61:1162:79fb:ff01::1

# Test API access
kubectl get nodes --server=https://api.k8s.lzadm.com:443
```

**Success criteria:**
- ✅ Service is LoadBalancer type after restart
- ✅ External IP is assigned: `2001:a61:1162:79fb:ff01::1`
- ✅ ExternalDNS maintains the DNS record
- ✅ API is accessible via `api.k8s.lzadm.com`

---

## Update kubeconfig

Once the LoadBalancer is stable, update your local kubeconfig:

```bash
# Backup current config
cp ~/.kube/config ~/.kube/config.backup

# Edit kubeconfig
nano ~/.kube/config

# Change server URL from:
#   server: https://k8s-node01:6443
# To:
#   server: https://api.k8s.lzadm.com:443
```

**Or use kubectl:**

```bash
# Update the server URL
kubectl config set-cluster default --server=https://api.k8s.lzadm.com:443

# Verify
kubectl cluster-info
```

---

## Troubleshooting

### Issue: Service Reverts to ClusterIP After Restart

**Symptoms:**
```bash
kubectl get svc kubernetes
# TYPE: ClusterIP (not LoadBalancer)
```

**Cause:** Auto-apply manifest not installed on server nodes

**Fix:**
1. Verify manifest exists on server nodes:
   ```bash
   ssh k8s-node01
   ls -la /var/lib/rancher/k3s/server/manifests/kubernetes-api-loadbalancer.yaml
   ```

2. If missing, create it following the steps in "Permanent Solution" above

3. Restart k3s to apply:
   ```bash
   sudo systemctl restart k3s
   ```

### Issue: TLS Certificate Validation Failed

**Symptoms:**
```
tls: failed to verify certificate: x509: certificate is valid for ... not api.k8s.lzadm.com
```

**Cause:** Certificate doesn't include LoadBalancer IP or DNS name

**Fix:**
1. Update `/etc/rancher/k3s/config.yaml` on each server node (see Step 3 above)
2. Restart k3s on each server node
3. Verify certificate SANs:
   ```bash
   openssl s_client -connect api.k8s.lzadm.com:443 </dev/null 2>/dev/null | \
     openssl x509 -noout -text | grep -A2 "Subject Alternative Name"
   ```

### Issue: DNS Record Not Created

**Symptoms:**
```bash
dig api.k8s.lzadm.com AAAA
# No answer
```

**Cause:** Service missing ExternalDNS annotation

**Fix:**
```bash
kubectl annotate svc kubernetes \
  external-dns.alpha.kubernetes.io/hostname=api.k8s.lzadm.com --overwrite

# Check ExternalDNS logs
kubectl logs -n external-dns -l app=external-dns --tail=20
```

### Issue: LoadBalancer IP Not Assigned

**Symptoms:**
```bash
kubectl get svc kubernetes
# EXTERNAL-IP: <pending>
```

**Cause:** MetalLB pool exhausted or misconfigured

**Fix:**
```bash
# Check MetalLB pool availability
kubectl get ipaddresspool -n metallb-system -o yaml

# Check MetalLB logs
kubectl logs -n metallb-system -l component=controller --tail=50
kubectl logs -n metallb-system -l component=speaker --tail=50

# Verify IP is available in pool
# Pool: 2001:a61:1162:79fb:ff01::/112 (65,536 IPs)
```

### Issue: Can't Connect via LoadBalancer IP

**Symptoms:**
```bash
curl -k https://[2001:a61:1162:79fb:ff01::1]
# Connection timeout
```

**Cause:** BGP route not advertised or MetalLB speaker issue

**Fix:**
```bash
# Check MetalLB speaker logs
kubectl logs -n metallb-system -l component=speaker

# Verify BGP session on pfSense
# SSH to pfSense
vtysh
show bgp ipv6 unicast summary
show bgp ipv6 unicast | grep ff01::1

# Should see route from Calico nodes (AS 65010)
```

---

## Maintenance

### Adding New Server Nodes

When adding new server nodes to the cluster:

1. **Configure TLS SANs** in `/etc/rancher/k3s/config.yaml`:
   ```yaml
   tls-san:
     - "api.k8s.lzadm.com"
     - "2001:a61:1162:79fb:ff01::1"
   ```

2. **Install auto-apply manifest**:
   ```bash
   sudo tee /var/lib/rancher/k3s/server/manifests/kubernetes-api-loadbalancer.yaml > /dev/null <<'EOF'
   [... manifest content ...]
   EOF
   ```

3. Join the cluster as usual

### Monitoring

Monitor the API LoadBalancer health:

```bash
# Check service status
kubectl get svc kubernetes -o wide

# Check endpoints (which nodes are serving API)
kubectl get endpoints kubernetes

# Check MetalLB speaker status
kubectl get pods -n metallb-system -l component=speaker

# Check ExternalDNS is managing the record
kubectl logs -n external-dns -l app=external-dns --tail=5
```

---

## Reference

### Complete Configuration Files

**k3s Server Config** (`/etc/rancher/k3s/config.yaml`):
```yaml
node-ip: 2001:a61:1162:79fb:xxxx:xxxx:xxxx:xxxx
cluster-domain: k8s.lzadm.com
cluster-cidr: '2001:a61:1162:79fb:ffcc::/112'
service-cidr: '2001:a61:1162:79fb:ff00::/112'
cluster-dns: '2001:a61:1162:79fb:ff00::10'
flannel-backend: none
disable-network-policy: true
kube-controller-manager-arg:
  - node-cidr-mask-size-ipv6=120
tls-san:
  - "ctrl.k8s.lzadm.com"
  - "k3s-cluster.k8s.lzadm.com"
  - "api.k8s.lzadm.com"                      # For LoadBalancer
  - "2001:a61:1162:79fb:ff01::1"             # LoadBalancer IP
disable:
  - traefik
```

**Auto-Apply Manifest** (`/var/lib/rancher/k3s/server/manifests/kubernetes-api-loadbalancer.yaml`):
```yaml
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
```

### Quick Recovery Script

If the LoadBalancer configuration is lost:

```bash
#!/bin/bash
# restore-api-lb.sh

echo "Restoring Kubernetes API LoadBalancer..."

kubectl patch svc kubernetes -p '{"spec":{"type":"LoadBalancer","loadBalancerIP":"2001:a61:1162:79fb:ff01::1"}}'
kubectl annotate svc kubernetes external-dns.alpha.kubernetes.io/hostname=api.k8s.lzadm.com --overwrite

echo "Waiting for MetalLB to assign IP..."
sleep 5

kubectl get svc kubernetes -o wide

echo "✅ Done! Verify DNS in 1-2 minutes with:"
echo "   dig api.k8s.lzadm.com AAAA +short"
```

---

## Related Documentation

- [MetalLB + Calico Configuration](LoadBalance.md)
- [ExternalDNS Setup](k3s-external-dns-pfsense.md)
- [k3s Cluster Setup](CLAUDE.md)
- [BGP Configuration](CLAUDE.md#configure-bgp-peering)
