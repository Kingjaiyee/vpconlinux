#!/usr/bin/env bash
set -euo pipefail
IFACE="${INTERNET_INTERFACE:-$(ip route show default | awk '/default/{print $5;exit}')}"

echo "== Create VPC and subnets =="; sudo ./vpcctl.sh create vpc1
sudo ./vpcctl.sh add-subnet vpc1 public  10.0.1.0/24
sudo ./vpcctl.sh add-subnet vpc1 private 10.0.2.0/24

echo "== Intra-VPC ping =="; sudo ip netns exec vpc-vpc1-public ping -c1 -W1 10.0.2.2
sudo ip netns exec vpc-vpc1-private ping -c1 -W1 10.0.1.2

echo "== NAT only for public =="; sudo ./vpcctl.sh nat-enable vpc1 10.0.1.0/24 "$IFACE"
sudo ip netns exec vpc-vpc1-public  bash -lc 'curl -sI http://example.com | head -n1'
sudo ip netns exec vpc-vpc1-private bash -lc 'timeout 2 curl -sI http://example.com || echo "private blocked (expected)"'

echo "== SG allow80/deny22 =="; sudo ./vpcctl.sh policy-apply vpc1 public policies/public-allow80-deny22.json
sudo ip netns exec vpc-vpc1-public bash -lc 'nohup python3 -m http.server 80 >/dev/null 2>&1 & sleep 1'
sudo ip netns exec vpc-vpc1-private curl -sI http://10.0.1.2:80 | head -n1
sudo ip netns exec vpc-vpc1-private bash -lc 'timeout 2 bash -c "</dev/tcp/10.0.1.2/22" && echo BAD || echo "22 blocked (good)"'

echo "== Optional Peering =="; sudo ./vpcctl.sh create vpc2
sudo ./vpcctl.sh add-subnet vpc2 public 10.1.1.0/24
sudo ./vpcctl.sh nat-enable vpc2 10.1.1.0/24 "$IFACE"
sudo ./vpcctl.sh peer vpc1 vpc2 10.0.0.0/16 10.1.0.0/16 "$IFACE"
sudo ip netns exec vpc-vpc1-public ping -c1 -W1 10.1.1.2
echo "Done."