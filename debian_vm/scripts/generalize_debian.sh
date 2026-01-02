#!/bin/bash
set -e

# Run as root
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*
rm -f /etc/udev/rules.d/70-persistent-net.rules
rm -f /var/lib/dhcp/*.leases
journalctl --vacuum-time=1s
apt clean
rm -rf /tmp/* /var/tmp/*
truncate -s 0 ~/.bash_history
history -c

echo "VM generalized. Shut down now and convert to template."
