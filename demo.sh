#!/usr/bin/env bash
set -Eeuo pipefail

# -------- Detect outbound interface --------
IFACE="$(ip route show default | awk '/default/{print $5;exit}')"
echo "[INFO] Using uplink interface: ${IFACE}"

# -------- 1) Clean up any previous run --------
sudo ./vpcctl.sh delete vpc1 || true

# -------- 2) Create VPC and subnets --------
sudo ./vpcctl.sh create vpc1
sudo ./vpcctl.sh add-subnet vpc1 public  10.200.1.0/24
sudo ./vpcctl.sh add-subnet vpc1 private 10.200.2.0/24

# NAT only for the PUBLIC subnet
sudo ./vpcctl.sh nat-enable vpc1 10.200.1.0/24 "${IFACE}"

# -------- 3) Basic connectivity tests --------
echo "[TEST] Intra-VPC ping (public ↔ private)"
sudo ip netns exec vpc-vpc1-public  ping -c2 -W1 10.200.2.2
sudo ip netns exec vpc-vpc1-private ping -c2 -W1 10.200.1.2

echo "[TEST] NAT (public -> internet)"
sudo ip netns exec vpc-vpc1-public bash -lc 'curl -sI http://example.com | head -n1'

echo "[TEST] Private -> internet (should FAIL)"
sudo ip netns exec vpc-vpc1-private bash -lc 'timeout 3 curl -sI http://example.com || echo NOINET ✅'

# -------- 4) Security group / policy examples --------
mkdir -p policies

# Public SG: allow TCP/8080, deny TCP/22
cat > policies/public-allow8080-deny22.json <<'JSON'
{
  "subnet": "10.200.1.0/24",
  "ingress": [
    { "port": 8080, "protocol": "tcp", "action": "allow" },
    { "port": 22,   "protocol": "tcp", "action": "deny"  }
  ]
}
JSON

# Private SG: default DROP, no explicit allows (empty ingress array)
# (Our CLI sets INPUT policy DROP and keeps ESTABLISHED,RELATED allowed)
cat > policies/private-deny-all.json <<'JSON'
{
  "subnet": "10.200.2.0/24",
  "ingress": []
}
JSON

sudo ./vpcctl.sh policy-apply vpc1 public  policies/public-allow8080-deny22.json
sudo ./vpcctl.sh policy-apply vpc1 private policies/private-deny-all.json

# -------- 5) Quick service check on public subnet --------
# Start a tiny HTTP server bound to the public subnet's host IP (10.200.1.2)
sudo ip netns exec vpc-vpc1-public bash -lc \
  'nohup python3 -m http.server 8080 --bind 10.200.1.2 >/tmp/pub.log 2>&1 & echo $! > /tmp/pub.pid'
sleep 1

echo "[TEST] HTTP on 10.200.1.2:8080 should be reachable"
curl -sI http://10.200.1.2:8080 | head -n1

echo "[TEST] SSH/22 on 10.200.1.2 should be BLOCKED by SG"
timeout 2 bash -lc 'exec 3<>/dev/tcp/10.200.1.2/22' \
  && echo "❌ PORT 22 OPEN (unexpected)" || echo "✅ PORT 22 BLOCKED"

# -------- 6) (Optional) Cleanup --------
# Comment these two lines if you want to inspect the VPC after the demo.
sudo ./vpcctl.sh delete vpc1 || true
echo "[DONE] Demo complete."
