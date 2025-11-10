#!/usr/bin/env bash
set -Eeuo pipefail

# Automatically detect interface
IFACE=$(ip route show default | awk '/default/{print $5;exit}')
echo "[INFO] Using uplink interface: $IFACE"

# 1️⃣ Clean up first
sudo ./vpcctl.sh delete vpc1 || true

# 2️⃣ Create and configure
sudo ./vpcctl.sh create vpc1
sudo ./vpcctl.sh add-subnet vpc1 public 10.0.1.0/24
sudo ./vpcctl.sh add-subnet vpc1 private 10.200.2.0/24
sudo ./vpcctl.sh nat-enable vpc1 10.0.1.0/24 "$IFACE"

# 3️⃣ Test connectivity
echo "[TEST] Intra-VPC ping"
sudo ip netns exec vpc-vpc1-public  ping -c2 -W1 10.200.2.2
sudo ip netns exec vpc-vpc1-private ping -c2 -W1 10.0.1.2

echo "[TEST] NAT (public -> internet)"
sudo ip netns exec vpc-vpc1-public bash -lc 'curl -sI http://example.com | head -n1'

echo "[TEST] Private -> internet (should fail)"
sudo ip netns exec vpc-vpc1-private bash -lc 'timeout 3 curl -sI http://example.com || echo NOINET ✅'

# 4️⃣ Apply policies
mkdir -p policies
cat > policies/public-allow8080-deny22.json <<'JSON'
{
  "subnet": "10.0.1.0/24",
  "ingress": [
    {"port": 8080, "protocol": "tcp", "action": "allow"},
    {"port": 22,   "protocol": "tcp", "action": "deny"}
  ]
}
JSON
cat > policies/private-deny-all.json <<'JSON'
{
  "subnet": "10.200.2.0/24",
  "ingress": [
    {"port": 0, "protocol": "tcp", "action": "deny"}
  ]
}
JSON

sudo ./vpcctl.sh policy-apply vpc1 public  policies/public-allow8080-deny22.json
sudo ./vpcctl.sh policy-apply vpc1 private policies/private-deny-all.json

# 5️⃣ Quick service check
sudo ip netns exec vpc-vpc1-public  bash -lc 'nohup python3 -m http.server 8080 --bind 10.0.1.2 >/tmp/pub.log 2>&1 &'
sleep 1
curl -sI http://10.0.1.2:8080 | head -n1
timeout 2 bash -lc 'exec 3<>/dev/tcp/10.0.1.2/22' || echo "PORT22_BLOCKED ✅"

# 6️⃣ Cleanup
sudo ./vpcctl.sh delete vpc1 || true
echo "[DONE] Demo complete."
