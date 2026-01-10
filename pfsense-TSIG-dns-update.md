# pfSense BIND TSIG Configuration for ExternalDNS

This guide configures TSIG (Transaction SIGnature) authentication on pfSense BIND to allow Kubernetes ExternalDNS to dynamically update DNS records in the `k8s.lzadm.com` zone.

## Prerequisites

- pfSense with BIND package installed (running on port 5353)
- `k8s.lzadm.com` zone configured as master zone
- SSH access to pfSense

## Step 1: Generate TSIG Key

SSH into pfSense and generate a TSIG key:

```bash
tsig-keygen -a hmac-sha256 externaldns-key
```

**Expected output:**
```
key "externaldns-key" {
    algorithm hmac-sha256;
    secret "kZ7P3mQx9vN2bF8aR5cT1wY6uH4jL0sD3gK9eM2pX7o=";
};
```

**Save this output** - you'll need:
- The entire key block → for BIND configuration
- Just the secret value → for Kubernetes Secret

## Step 2: Add Key to pfSense BIND

1. Navigate to: **Services → BIND DNS Server → Advanced Settings**

2. Find: **Global Settings** section

3. Paste the entire key block:
   ```
   key "externaldns-key" {
       algorithm hmac-sha256;
       secret "YOUR_SECRET_HERE";
   };
   ```

4. Click: **Save**

## Step 3: Configure Zone for Dynamic Updates

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
   This grants the key permission to update any record type in the zone and all subdomains.

4. Click: **Save**

5. Click: **Apply Configuration** (top of page)

## Step 4: Verify BIND Configuration

SSH to pfSense and verify the configuration:

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

## Step 5: Test Dynamic Update

Test from a k8s node or any machine with `nsupdate` installed.

**Replace `YOUR_SECRET` and pfSense IPv6 address as needed:**

```bash
# Set variables
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

# Expected output: 2001:a61:1162:79fb:ff01::99

# Delete test record (cleanup)
nsupdate -y hmac-sha256:externaldns-key:${TSIG_SECRET} -p ${BIND_PORT} << EOF
server ${PFSENSE_DNS}
zone k8s.lzadm.com
update delete test-externaldns.k8s.lzadm.com AAAA
send
EOF

# Verify deletion
dig @${PFSENSE_DNS} -p ${BIND_PORT} test-externaldns.k8s.lzadm.com AAAA +short
# Expected: no output
```

## Step 6: Update Kubernetes Secret

Once TSIG is working, update the ExternalDNS secret in `external-dns-rfc2136.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: external-dns-rfc2136
  namespace: external-dns
type: Opaque
stringData:
  tsig-secret: "YOUR_SECRET_HERE"
```

Then deploy:
```bash
kubectl apply -f external-dns-rfc2136.yaml
```

## Troubleshooting

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `TSIG verify failure (BADKEY)` | Key name or secret mismatch | Verify key name and secret match exactly on both sides |
| `REFUSED` | Zone doesn't allow updates | Check `allow-update` includes the key |
| `NOTAUTH` | Wrong zone or not authoritative | Verify zone name and that BIND is master for zone |
| `SERVFAIL` | BIND can't write zone file | Check file permissions on `/var/etc/named/etc/namedb/master/` |
| `connection refused` | Wrong port or BIND not running | Verify BIND is running and listening on port 5353 |

### View BIND Logs

```bash
# pfSense resolver log
clog /var/log/resolver.log | tail -50

# System log
grep named /var/log/system.log | tail -20

# Check BIND is running
sockstat -l | grep named
```

### Verify BIND is Listening

```bash
# Check BIND is listening on port 5353
sockstat -l | grep 5353

# Test DNS query
dig @::1 -p 5353 k8s.lzadm.com SOA
```

### Debug nsupdate

Add `-d` flag for debug output:
```bash
nsupdate -d -y hmac-sha256:externaldns-key:${TSIG_SECRET} -p 5353 << EOF
server ${PFSENSE_DNS}
zone k8s.lzadm.com
update add test.k8s.lzadm.com 300 AAAA 2001:a61:1162:79fb:ff01::1
send
EOF
```

## Rotating TSIG Secret

If you need to regenerate the TSIG key (for security rotation or compromise):

### Quick Command Sequence

```bash
# 1. Generate new TSIG key on pfSense
tsig-keygen -a hmac-sha256 externaldns-key
# Copy the new secret value

# 2. Update pfSense BIND (Services → BIND DNS Server → Advanced Settings → Global Settings)
# Replace the key block with new secret and click Save

# 3. Update Kubernetes secret
kubectl patch secret external-dns-rfc2136 -n external-dns \
  -p '{"stringData":{"tsig-secret":"NEW_SECRET_HERE"}}'

# 4. Restart ExternalDNS
kubectl rollout restart deployment/external-dns -n external-dns

# 5. Verify
kubectl logs -n external-dns -l app=external-dns --tail=10
```

**Expected verification output:**
```
level=info msg="Configured RFC2136 with zone '[k8s.lzadm.com]'"
level=info msg="All records are already up to date"
```

See [k3s-external-dns-pfsense.md](k3s-external-dns-pfsense.md#rotatingupdating-tsig-secret) for detailed steps.

## Security Considerations

- **Protect the TSIG secret** - it provides write access to your DNS zone
- **Use strong keys** - hmac-sha256 with 256-bit keys is recommended
- **Limit scope** - the `zonesub` grant allows updates to all records; consider more restrictive policies if needed
- **Monitor updates** - check BIND logs periodically for unauthorized update attempts

## References

- [pfSense BIND RFC 2136 Documentation](https://docs.netgate.com/pfsense/en/latest/recipes/bind-rfc2136.html)
- [ExternalDNS RFC2136 Provider](https://kubernetes-sigs.github.io/external-dns/latest/docs/tutorials/rfc2136/)
- [BIND 9 TSIG Documentation](https://bind9.readthedocs.io/en/latest/chapter6.html#tsig)
