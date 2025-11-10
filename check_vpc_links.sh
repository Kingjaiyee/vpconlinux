#!/usr/bin/env bash
set -Eeuo pipefail

ns_exists(){ ip netns list | awk '{print $1}' | grep -qx "$1"; }

hr(){ printf "\n==== %s ====\n" "$*"; }

show_ns_links(){
  local ns="$1"
  if ns_exists "$ns"; then
    hr "ip link (@ $ns)"
    sudo nsenter --net="/var/run/netns/$ns" ip link show
  else
    echo "[miss] $ns"
  fi
}

show_router_bridge(){
  local rns="$1" br="$2"
  if ns_exists "$rns"; then
    hr "Bridge membership (@ $rns)"
    sudo nsenter --net="/var/run/netns/$rns" bridge link || true

    hr "Bridge addresses (@ $rns:$br)"
    sudo nsenter --net="/var/run/netns/$rns" ip addr show "$br" || true

    hr "FDB table (@ $rns:$br)"
    sudo nsenter --net="/var/run/netns/$rns" bridge fdb show | sed -n '1,30p' || true
  fi
}

show_routes(){
  local ns="$1"
  if ns_exists "$ns"; then
    hr "Routes (@ $ns)"
    sudo nsenter --net="/var/run/netns/$ns" ip route show
  fi
}

check_forwarding(){
  hr "Host forwarding & FORWARD policy"
  sysctl net.ipv4.ip_forward
  echo -n "FORWARD policy: "
  sudo iptables -S FORWARD | head -n1
}

show_nat(){
  hr "NAT table (POSTROUTING)"
  sudo iptables -t nat -S POSTROUTING | nl
}

# ---------- entrypoint ----------
VPC="${1:-vpc1}"       # default vpc1
BR="br-${VPC}"
RNS="vpc-${VPC}-rt"
PUB="vpc-${VPC}-public"
PRV="vpc-${VPC}-private"

echo "Inspecting VPC=${VPC}"
check_forwarding

show_ns_links "$RNS"
show_router_bridge "$RNS" "$BR"

show_ns_links "$PUB"
show_routes "$PUB"

show_ns_links "$PRV"
show_routes "$PRV"

show_nat

cat <<EOF

Hints:
- Router bridge should list two veth ports in "Bridge membership".
- Public/Private namespaces should each have one veth (state UP).
- If 'bridge link' is empty: router-side veths aren't enslaved to $BR.
- If internet fails for public: confirm MASQUERADE in POSTROUTING.

Run:  ./check_vpc_links.sh [vpc-name]
EOF