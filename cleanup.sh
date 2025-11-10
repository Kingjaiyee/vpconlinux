#!/usr/bin/env bash
set -Eeuo pipefail
sudo ./vpcctl.sh delete vpc2 || true
sudo ./vpcctl.sh delete vpc1 || true
echo "Review nat rules (delete by number with -D as needed):"
sudo iptables -t nat -S | nl