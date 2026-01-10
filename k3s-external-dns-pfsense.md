# ExternalDNS with pfSense BIND (RFC2136)

This guide configures ExternalDNS to automatically manage DNS records in pfSense BIND for Kubernetes LoadBalancer services. ExternalDNS uses RFC2136 (Dynamic DNS Updates) with TSIG authentication.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster                                                      │
│                                                                          │
│  LoadBalancer Service              ExternalDNS                          │
│  (whoami, 79fb:ff01::X)  ────────▶ (watches services)                   │
│         │                                   │                            │
│         │                                   │ RFC2136 + TSIG             │
│         │                                   ▼                            │
│         │                          pfSense BIND (:5353)                  │
│         │                          ┌─────────────────┐                   │
│         │                          │ k8s.lzadm.com   │                   │
│         │                          │ whoami = ff01:: │                   │
│         │                          └─────────────────┘                   │
└─────────┼────────────────────────────────────────────────────────────────┘
          │
          ▼
    Home network queries whoami.k8s.lzadm.com → LoadBalancer IP
```

**How it works:**
1. You create a LoadBalancer service with `external-dns.alpha.kubernetes.io/hostname` annotation
2. ExternalDNS detects the service and its external IP
3. ExternalDNS sends RFC2136 dynamic update to pfSense BIND
4. BIND creates/updates the DNS record
5. Home network devices can now resolve the hostname

## Prerequisites

- pfSense with BIND package installed (configured on port 5353)
- `k8s.lzadm.com` zone configured as master zone in BIND
- SSH access to pfSense
- k3s cluster with LoadBalancer support (MetalLB or similar)

---

## Part 1: pfSense TSIG Configuration

### Step 1.1: Generate TSIG Key

SSH into pfSense and generate a TSIG key:

```bash
tsig-keygen -a hmac-sha256 externaldns-key
```

**Expected output:**
```
key "externaldns-key" {
    algorithm hmac-sha256;
    secret "Pp0e06e3JezXY3StRNSmYu5OcJD1z0z5Q5zAUYYsX6U=";
};
```

**Save this output:**
- The entire key block → for BIND configuration (Step 1.2)
- Just the secret value → for Kubernetes Secret (Part 2)

### Step 1.2: Add Key to pfSense BIND

1. Navigate to: **Services → BIND DNS Server → Settings**

2. Click: **Show Advanced Options** (bottom of page)

3. Find: **Custom Options** field

4. Paste the entire key block:
   ```
   key "externaldns-key" {
       algorithm hmac-sha256;
       secret "YOUR_SECRET_HERE";
   };
   ```

5. Click: **Save**

### Step 1.3: Configure Zone for Dynamic Updates

1. Navigate to: **Services → BIND DNS Server → Zones**

2. Click **Edit** on the `k8s.lzadm.com` zone

3. Configure the following fields:

   | Field | Value |
   |-------|-------|
   | Allow Update | `key "externaldns-key";` |
   | Allow Transfer | `key "externaldns-key";` |

   **Alternative - Update Policy (more granular control):**
   ```
   grant externaldns-key zonesub ANY;
   ```

4. Click: **Save**

5. Click: **Apply Configuration** (top of page)

### Step 1.4: Verify BIND Configuration

SSH to pfSense and verify:

```bash
# Check if key is in config
grep -A3 "externaldns-key" /var/etc/named/etc/namedb/named.conf

# Check zone configuration
grep -A10 "k8s.lzadm.com" /var/etc/named/etc/namedb/named.conf
```

**Expected zone configuration:**
```
zone "k8s.lzadm.com" {
    type master;
    file "/var/etc/named/etc/namedb/master/k8s.lzadm.com.db";
    allow-update { key "externaldns-key"; };
    allow-transfer { key "externaldns-key"; };
};
```

### Step 1.5: Test Dynamic Update Manually

Test from a k8s node or any machine with `nsupdate`:

```bash
# Set variables (update with your values)
PFSENSE_DNS="2001:a61:1162:79fb:2e0:4cff:fe68:9ff"
TSIG_SECRET="YOUR_SECRET_HERE"
BIND_PORT=5353

# Create test record
nsupdate -y hmac-sha256:externaldns-key:${TSIG_SECRET} -p ${BIND_PORT} << EOF
server ${PFSENSE_DNS}
zone k8s.lzadm.com
update add test-externaldns.k8s.lzadm.com 300 AAAA 2001:a61:1162:79fb:ff01::99
send
EOF

# Verify record was created
dig @${PFSENSE_DNS} -p ${BIND_PORT} test-externaldns.k8s.lzadm.com AAAA +short
# Expected: 2001:a61:1162:79fb:ff01::99

# Delete test record (cleanup)
nsupdate -y hmac-sha256:externaldns-key:${TSIG_SECRET} -p ${BIND_PORT} << EOF
server ${PFSENSE_DNS}
zone k8s.lzadm.com
update delete test-externaldns.k8s.lzadm.com AAAA
send
EOF
```

---

## Part 2: Kubernetes ExternalDNS Deployment

### Step 2.1: Create the Manifest

Create `external-dns-rfc2136.yaml`:

```yaml
# ExternalDNS for BIND on pfSense using RFC2136 (Dynamic DNS Updates)
---
apiVersion: v1
kind: Namespace
metadata:
  name: external-dns

---
# TSIG Secret for RFC2136 authentication
# IMPORTANT: Replace with your actual TSIG secret from Step 1.1
apiVersion: v1
kind: Secret
metadata:
  name: external-dns-rfc2136
  namespace: external-dns
type: Opaque
stringData:
  tsig-secret: "YOUR_TSIG_SECRET_HERE"

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-dns
  namespace: external-dns

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: external-dns
rules:
  - apiGroups: [""]
    resources: ["services", "endpoints", "pods", "nodes"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["get", "watch", "list"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: external-dns-viewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: external-dns
subjects:
  - kind: ServiceAccount
    name: external-dns
    namespace: external-dns

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-dns
  namespace: external-dns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: external-dns
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: external-dns
    spec:
      serviceAccountName: external-dns
      containers:
        - name: external-dns
          image: registry.k8s.io/external-dns/external-dns:v0.15.0
          args:
            # Provider configuration
            - --provider=rfc2136

            # pfSense BIND server (IPv6 address)
            - --rfc2136-host=2001:a61:1162:79fb:2e0:4cff:fe68:9ff

            # pfSense BIND runs on port 5353 (non-standard)
            - --rfc2136-port=5353

            # Zone to manage
            - --rfc2136-zone=k8s.lzadm.com

            # TSIG authentication
            - --rfc2136-tsig-keyname=externaldns-key
            - --rfc2136-tsig-secret=$(TSIG_SECRET)
            - --rfc2136-tsig-secret-alg=hmac-sha256

            # Enable zone transfer for proper record management
            - --rfc2136-tsig-axfr

            # Default TTL for records (must include time unit)
            - --rfc2136-min-ttl=300s

            # Sources to watch
            - --source=service
            - --source=ingress

            # Only manage records in k8s.lzadm.com domain
            - --domain-filter=k8s.lzadm.com

            # Registry for tracking ownership (prevents conflicts)
            - --registry=txt
            - --txt-owner-id=k8s-cluster
            - --txt-prefix=externaldns-

            # Policy: sync will delete records when services are removed
            # Use 'upsert-only' if you don't want automatic deletion
            - --policy=sync

            # Logging
            - --log-level=info
            - --log-format=text

            # Update interval
            - --interval=1m
          env:
            - name: TSIG_SECRET
              valueFrom:
                secretKeyRef:
                  name: external-dns-rfc2136
                  key: tsig-secret
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "100m"
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

### Step 2.2: Update the Secret

Edit the manifest and replace `YOUR_TSIG_SECRET_HERE` with your actual TSIG secret:

```yaml
stringData:
  tsig-secret: "Pp0e06e3JezXY3StRNSmYu5OcJD1z0z5Q5zAUYYsX6U="
```

### Step 2.3: Deploy ExternalDNS

```bash
kubectl apply -f external-dns-rfc2136.yaml
```

### Step 2.4: Verify Deployment

```bash
# Check pod status
kubectl get pods -n external-dns

# Check logs
kubectl logs -n external-dns -l app=external-dns

# Expected log output:
# level=info msg="Configured RFC2136 with zone '[k8s.lzadm.com]' and nameserver '[...]:5353'"
# level=info msg="All records are already up to date"
```

---

## Part 3: Usage

### Expose a Service via DNS

Add the `external-dns.alpha.kubernetes.io/hostname` annotation to any LoadBalancer service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
  annotations:
    external-dns.alpha.kubernetes.io/hostname: myapp.k8s.lzadm.com
    external-dns.alpha.kubernetes.io/ttl: "300"  # optional
spec:
  type: LoadBalancer
  selector:
    app: myapp
  ports:
    - port: 80
      targetPort: 8080
```

### Add Annotation to Existing Service

```bash
kubectl annotate svc myapp external-dns.alpha.kubernetes.io/hostname=myapp.k8s.lzadm.com
```

### Verify DNS Record

```bash
# Query pfSense BIND directly
dig @2001:a61:1162:79fb:2e0:4cff:fe68:9ff -p 5353 myapp.k8s.lzadm.com AAAA +short

# Check ExternalDNS logs
kubectl logs -n external-dns -l app=external-dns --tail=20
```

### Multiple Hostnames

A service can have multiple DNS names:

```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/hostname: app.k8s.lzadm.com,www.k8s.lzadm.com
```

---

## Part 4: Troubleshooting

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `TSIG verify failure (BADKEY)` | Key name or secret mismatch | Verify key name and secret match exactly |
| `REFUSED` | Zone doesn't allow updates | Check `allow-update` in zone config |
| `NOTAUTH` | Wrong zone or not authoritative | Verify zone name and BIND is master |
| `SERVFAIL` | BIND can't write zone file | Check file permissions |
| `connection refused` | Wrong port or BIND not running | Verify BIND on port 5353 |
| `time: missing unit in duration` | TTL without time unit | Use `300s` not `300` |

### View ExternalDNS Logs

```bash
# Follow logs
kubectl logs -n external-dns -l app=external-dns -f

# Check for errors
kubectl logs -n external-dns -l app=external-dns | grep -i error
```

### View BIND Logs on pfSense

```bash
# pfSense resolver log
clog /var/log/resolver.log | tail -50

# System log
grep named /var/log/system.log | tail -20
```

### Debug nsupdate

```bash
nsupdate -d -y hmac-sha256:externaldns-key:${TSIG_SECRET} -p 5353 << EOF
server ${PFSENSE_DNS}
zone k8s.lzadm.com
update add test.k8s.lzadm.com 300 AAAA 2001:a61:1162:79fb:ff01::1
send
EOF
```

### Verify Records in BIND

```bash
# List all records ExternalDNS created
dig @2001:a61:1162:79fb:2e0:4cff:fe68:9ff -p 5353 k8s.lzadm.com AXFR

# Check specific record
dig @2001:a61:1162:79fb:2e0:4cff:fe68:9ff -p 5353 whoami.k8s.lzadm.com AAAA

# Check TXT ownership record
dig @2001:a61:1162:79fb:2e0:4cff:fe68:9ff -p 5353 externaldns-aaaa-whoami.k8s.lzadm.com TXT
```

---

## Part 5: Configuration Reference

### ExternalDNS Arguments

| Argument | Description |
|----------|-------------|
| `--provider=rfc2136` | Use RFC2136 dynamic DNS updates |
| `--rfc2136-host` | DNS server address |
| `--rfc2136-port` | DNS server port (default: 53) |
| `--rfc2136-zone` | Zone to manage |
| `--rfc2136-tsig-keyname` | TSIG key name |
| `--rfc2136-tsig-secret` | TSIG secret value |
| `--rfc2136-tsig-secret-alg` | Algorithm (hmac-sha256) |
| `--rfc2136-tsig-axfr` | Enable zone transfers |
| `--rfc2136-min-ttl` | Minimum TTL (e.g., 300s) |
| `--source` | What to watch (service, ingress) |
| `--domain-filter` | Only manage this domain |
| `--policy` | sync (create/update/delete) or upsert-only |
| `--registry` | Record ownership tracking (txt) |
| `--txt-owner-id` | Unique cluster identifier |
| `--txt-prefix` | Prefix for TXT ownership records |
| `--interval` | Sync interval (e.g., 1m) |

### Service Annotations

| Annotation | Description |
|------------|-------------|
| `external-dns.alpha.kubernetes.io/hostname` | DNS hostname(s) to create |
| `external-dns.alpha.kubernetes.io/ttl` | Record TTL in seconds |
| `external-dns.alpha.kubernetes.io/target` | Override target IP/hostname |

---

## Security Considerations

- **Protect the TSIG secret** - it provides write access to your DNS zone
- **Use strong keys** - hmac-sha256 with 256-bit keys is recommended
- **Limit scope** - `zonesub` allows updates to all records; consider more restrictive policies
- **Monitor updates** - check BIND logs for unauthorized update attempts
- **Use `--policy=sync`** - ensures stale records are cleaned up when services are deleted

---

## References

- [ExternalDNS RFC2136 Tutorial](https://kubernetes-sigs.github.io/external-dns/latest/docs/tutorials/rfc2136/)
- [ExternalDNS GitHub](https://github.com/kubernetes-sigs/external-dns)
- [pfSense BIND RFC 2136 Documentation](https://docs.netgate.com/pfsense/en/latest/recipes/bind-rfc2136.html)
- [BIND 9 TSIG Documentation](https://bind9.readthedocs.io/en/latest/chapter6.html#tsig)
