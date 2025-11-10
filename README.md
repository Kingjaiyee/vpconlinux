# Build-Your-Own VPC on Linux (Namespaces + veth + Bridge + NAT)

This project recreates a cloud-style VPC using pure Linux primitives.
- Namespaces per subnet
- veth pairs as virtual cables
- Linux bridge as the VPC router
- Routing between subnets
- NAT for public subnet
- Security Groups with iptables (policy files)
- Optional VPC peering with NAT exclusions

Recording Script

Show: create → add subnets → ping intra-VPC → NAT (public OK, private blocked) → SG allow80/deny22 → optional peering → teardown.

Notes

Run with sudo.

If pings fail, ensure sysctl net.ipv4.ip_forward=1 and iptables -P FORWARD ACCEPT.


## Quickstart
```bash
chmod +x vpcctl.sh demo.sh cleanup.sh
make up
make nat
make policy
make test
# optional:
make peer
make down

