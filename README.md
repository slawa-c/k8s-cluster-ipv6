# Kubernetes cluster in home lab with IPv6 only setup

## Description

The main idea is to deploy kubernetes cluster in my home lab in subnet where only IPv6 network available, for sure I configured my pfsense router with DNS64 and NAT64 features to provide communications from ipv6 only enabled hosts to ipv4 only resources in Internet.

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

### nsupdate script for updating DNS names in home lab DNS zone.

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

### generate ssh host keys

```bash
/usr/bin/ssh-keygen -A
systemctl restart ssh
```

### add admin user
adduser admin
usermod -aG sudo admin

### make sysctl changes:
echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.accept_ra = 2" >> /etc/sysctl.conf
sysctl -p

### check ipv6 prefix
rdisc6 -q enp2s0