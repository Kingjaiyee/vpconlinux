#!/usr/bin/env bash
set -Eeuo pipefail

# ---------- utils ----------
log(){ echo "[$(date +'%F %T')] $*"; }
need_root(){ [ "$EUID" -eq 0 ] || exec sudo -E bash "$0" "$@"; }
need_root "$@"

exists_ns(){ ip netns list | awk '{print $1}' | grep -qx "$1"; }
gw_from_cidr(){ awk -F'[./]' '{printf "%s.%s.%s.1\n",$1,$2,$3}' <<<"$1"; }   # assumes /24
net_from_cidr(){ cut -d/ -f1 <<<"$1"; }
mask_from_cidr(){ cut -d/ -f2 <<<"$1"; }

# ---------- primitives ----------
create_bridge() {
  local ns="$1" br="$2"
  if ! exists_ns "$ns"; then
    log "Create router namespace $ns"
    ip netns add "$ns"
  else
    log "Router namespace $ns exists"
  fi
  ip -n "$ns" link set lo up

  if ! ip -n "$ns" link show "$br" &>/dev/null; then
    log "Create bridge $ns/$br"
    ip -n "$ns" link add "$br" type bridge
  else
    log "Bridge $ns/$br exists"
  fi

  ip -n "$ns" link set "$br" up
  ip netns exec "$ns" sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

create_subnet_ns() {
  local ns="$1"
  if ! exists_ns "$ns"; then
    log "Create subnet namespace $ns"
    ip netns add "$ns"
  else
    log "Subnet namespace $ns exists"
  fi
  ip -n "$ns" link set lo up
}

# FIXED: create when either end is missing, delete orphans, always enslave to bridge
create_veth_to_bridge(){
  # host_ns vethA  router_ns vethB  bridge_if
  local host_ns="$1" vA="$2" rns="$3" vB="$4" br="$5"

  # (Re)create pair if either end is missing
  if ! ( ip -n "$host_ns" link show "$vA" &>/dev/null && ip -n "$rns" link show "$vB" &>/dev/null ); then
    # Clean up possible half-created ends to avoid "File exists"
    ip -n "$host_ns" link show "$vA" &>/dev/null && ip -n "$host_ns" link del "$vA" || true
    ip -n "$rns"     link show "$vB" &>/dev/null && ip -n "$rns"     link del "$vB" || true

    log "Create veth $host_ns:$vA <-> $rns:$vB"
    ip link add "$vA" netns "$host_ns" type veth peer name "$vB" netns "$rns"
  else
    log "Veth $host_ns:$vA <-> $rns:$vB exists"
  fi

  # Ensure both ends are up
  ip -n "$host_ns" link set "$vA" up
  ip -n "$rns"     link set "$vB" up

  # Ensure router end is attached to bridge
  ip -n "$rns" link set "$vB" master "$br" 2>/dev/null || {
    log "Attach $rns:$vB to bridge $br"
    ip -n "$rns" link set "$vB" master "$br"
  }
}

# Safer: only add IP if not present; always ensure default route
assign_ips_and_routes(){
  # ns veth ip_cidr gw
  local ns="$1" veth="$2" ipcidr="$3" gw="$4"
  ip -n "$ns" addr show dev "$veth" | grep -q " $ipcidr" || {
    ip -n "$ns" addr flush dev "$veth" || true
    ip -n "$ns" addr add "$ipcidr" dev "$veth"
  }
  ip -n "$ns" route replace default via "$gw" dev "$veth"
}

connect_bridges(){
  # ns1 br1 ns2 br2
  local ns1="$1" br1="$2" ns2="$3" br2="$4"
  local p1="veth_${br2}" p2="veth_${br1}"

  if ! ( ip -n "$ns1" link show "$p1" &>/dev/null && ip -n "$ns2" link show "$p2" &>/dev/null ); then
    log "Connect bridges $ns1/$br1 <-> $ns2/$br2"
    # remove orphans if any
    ip -n "$ns1" link show "$p1" &>/dev/null && ip -n "$ns1" link del "$p1" || true
    ip -n "$ns2" link show "$p2" &>/dev/null && ip -n "$ns2" link del "$p2" || true
    ip link add "$p1" netns "$ns1" type veth peer name "$p2" netns "$ns2"
  else
    log "Bridge interconnect exists"
  fi

  ip -n "$ns1" link set "$p1" up
  ip -n "$ns2" link set "$p2" up
  ip -n "$ns1" link set "$p1" master "$br1"
  ip -n "$ns2" link set "$p2" master "$br2"
}

# ---------- orchestration ----------
vpc_create(){
  local vpc="$1"
  [ -n "${vpc:-}" ] || { echo "Usage: $0 create <VPC>"; exit 1; }
  local rns="vpc-${vpc}-rt" br="br-${vpc}"
  create_bridge "$rns" "$br"
  log "VPC $vpc ready (router=$rns bridge=$br)"
}

vpc_add_subnet(){
  # add-subnet <VPC> <SUBNET_NAME> <CIDR>
  local vpc="$1" sname="$2" cidr="$3"
  [ -n "$vpc" ] && [ -n "$sname" ] && [ -n "$cidr" ] || { echo "Usage: $0 add-subnet <VPC> <SUBNET> <CIDR>"; exit 1; }

  local rns="vpc-${vpc}-rt" br="br-${vpc}" sns="vpc-${vpc}-${sname}"
  local gw mask net host_ip
  gw=$(gw_from_cidr "$cidr")
  mask=$(mask_from_cidr "$cidr")
  net=$(net_from_cidr "$cidr")
  host_ip="$(awk -F. '{printf "%s.%s.%s.2\n",$1,$2,$3}' <<<"$net")"

  create_bridge "$rns" "$br"
  create_subnet_ns "$sns"

  # give bridge the gateway for this subnet if missing
  ip -n "$rns" addr show "$br" | grep -q " $gw/" || ip -n "$rns" addr add "$gw/$mask" dev "$br"

  local vA="veth-${vpc}-${sname}" vB="veth-${vpc}-${sname}-br"
  create_veth_to_bridge "$sns" "$vA" "$rns" "$vB" "$br"
  assign_ips_and_routes "$sns" "$vA" "${host_ip}/${mask}" "$gw"

  log "Subnet $sns ($cidr) attached (gw=$gw ip=${host_ip}/${mask})"
}

vpc_enable_nat(){
  # nat-enable <VPC> <PUBLIC_CIDR> <HOST_IFACE>
  local vpc="$1" cidr="$2" iface="$3"
  [ -n "$vpc" ] && [ -n "$cidr" ] && [ -n "$iface" ] || { echo "Usage: $0 nat-enable <VPC> <CIDR> <IFACE>"; exit 1; }
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s "$cidr" -o "$iface" -j MASQUERADE 2>/dev/null || {
    log "Add MASQUERADE for $cidr -> $iface"
    iptables -t nat -A POSTROUTING -s "$cidr" -o "$iface" -j MASQUERADE
  }
  log "NAT enabled for $vpc ($cidr via $iface)"
}

vpc_peer(){
  # peer <VPC_A> <VPC_B> <CIDR_A> <CIDR_B> <HOST_IFACE>
  local a="$1" b="$2" cidrA="$3" cidrB="$4" iface="$5"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$cidrA" ] && [ -n "$cidrB" ] && [ -n "$iface" ] || {
    echo "Usage: $0 peer <VPC_A> <VPC_B> <CIDR_A> <CIDR_B> <HOST_IFACE>"; exit 1; }

  local rA="vpc-${a}-rt" brA="br-${a}"
  local rB="vpc-${b}-rt" brB="br-${b}"
  create_bridge "$rA" "$brA"
  create_bridge "$rB" "$brB"
  connect_bridges "$rA" "$brA" "$rB" "$brB"

  # static routes at router namespaces
  ip -n "$rA" route replace "$cidrB" dev "$brA"
  ip -n "$rB" route replace "$cidrA" dev "$brB"

  # NAT peering exclusions (must precede MASQUERADE)
  iptables -t nat -C POSTROUTING -s "$cidrA" -d "$cidrB" -j RETURN 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s "$cidrA" -d "$cidrB" -j RETURN
  iptables -t nat -C POSTROUTING -s "$cidrB" -d "$cidrA" -j RETURN 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s "$cidrB" -d "$cidrA" -j RETURN
  iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE

  log "Peered $a <$cidrA> with $b <$cidrB> (NAT exclusions set)"
}

vpc_policy_apply(){
  # policy-apply <VPC> <SUBNET> <policy.json>
  local vpc="$1" sname="$2" file="$3"
  [ -f "$file" ] || { echo "Policy file not found: $file"; exit 1; }
  local ns="vpc-${vpc}-${sname}"

  # minimal JSON parse: {"ingress":[{"port":80,"protocol":"tcp","action":"allow"},...]}
  local rules
  rules=$(tr -d '\n\r ' < "$file" | sed 's/.*"ingress":\[\(.*\)\].*/\1/' | tr '}' '\n' | sed 's/^{//;s/,*$//')

  ip -n "$ns" iptables -P INPUT DROP
  ip -n "$ns" iptables -F INPUT
  ip -n "$ns" iptables -A INPUT -i lo -j ACCEPT
  ip -n "$ns" iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  while IFS= read -r r; do
    [ -z "$r" ] && continue
    local port proto action
    port=$(sed -n 's/.*"port":\([0-9]\+\).*/\1/p' <<<"$r")
    proto=$(sed -n 's/.*"protocol":"\([a-z]\+\)".*/\1/p' <<<"$r")
    action=$(sed -n 's/.*"action":"\([a-z]\+\)".*/\1/p' <<<"$r")
    [ -z "$port" -o -z "$proto" -o -z "$action" ] && continue
    if [ "$action" = "allow" ]; then
      ip -n "$ns" iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT
      log "Allow $proto/$port on $ns"
    else
      ip -n "$ns" iptables -A INPUT -p "$proto" --dport "$port" -j DROP
      log "Deny  $proto/$port on $ns"
    fi
  done <<< "$rules"

  log "Applied SG policy to $ns"
}

vpc_delete(){
  local vpc="$1"; [ -n "$vpc" ] || { echo "Usage: $0 delete <VPC>"; exit 1; }
  local rns="vpc-${vpc}-rt"
  for ns in $(ip netns list | awk '{print $1}' | grep "^vpc-${vpc}-" | grep -v -- "-rt$" || true); do
    log "Delete subnet ns $ns"
    ip netns del "$ns" || true
  done
  if exists_ns "$rns"; then
    log "Delete router ns $rns"
    ip netns del "$rns" || true
  fi
  log "VPC $vpc removed"
}

vpc_list(){
  echo "VPC Routers:"; ip netns list | awk '{print $1}' | grep -- "-rt$" || true
  echo "Subnets:";    ip netns list | awk '{print $1}' | grep -- "^vpc-.*-" | grep -v -- "-rt$" || true
}

usage(){
cat <<EOF
Usage:
  $0 create <VPC>
  $0 add-subnet <VPC> <SUBNET> <CIDR>
  $0 nat-enable <VPC> <PUBLIC_CIDR> <HOST_IFACE>
  $0 peer <VPC_A> <VPC_B> <CIDR_A> <CIDR_B> <HOST_IFACE>
  $0 policy-apply <VPC> <SUBNET> <policy.json>
  $0 delete <VPC>
  $0 list
Notes:
  - /24 assumption for gateway calc (10.x.y.1). Extend gw_from_cidr for other masks.
  - Run with sudo (the script will re-exec with sudo if needed).
EOF
}

cmd="${1:-}"; shift || true
case "${cmd:-}" in
  create)        vpc_create "$@";;
  add-subnet)    vpc_add_subnet "$@";;
  nat-enable)    vpc_enable_nat "$@";;
  peer)          vpc_peer "$@";;
  policy-apply)  vpc_policy_apply "$@";;
  delete)        vpc_delete "$@";;
  list)          vpc_list;;
  *)             usage; exit 1;;
esac
