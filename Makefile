SHELL := /bin/bash

# Default interface automatically detected
IFACE ?= $(shell ip route show default | awk '/default/{print $$5;exit}')

.PHONY: help up nat policy peer test list down nuke demo

help:
	@echo "Targets: up nat policy peer test list down nuke demo"

# -----------------------------
# 1️⃣  Bring up VPC1 with public/private subnets
# -----------------------------
up:
	sudo ./vpcctl.sh create vpc1
	sudo ./vpcctl.sh add-subnet vpc1 public 10.0.1.0/24
	sudo ./vpcctl.sh add-subnet vpc1 private 10.200.2.0/24

# -----------------------------
# 2️⃣  Enable NAT for public subnet
# -----------------------------
nat:
	sudo ./vpcctl.sh nat-enable vpc1 10.0.1.0/24 $(IFACE)

# -----------------------------
# 3️⃣  Apply Security Group–like rules
# -----------------------------
policy:
	sudo ./vpcctl.sh policy-apply vpc1 public policies/public-allow8080-deny22.json
	sudo ./vpcctl.sh policy-apply vpc1 private policies/private-deny-all.json

# -----------------------------
# 4️⃣  Create a second VPC and peer
# -----------------------------
peer:
	sudo ./vpcctl.sh create vpc2
	sudo ./vpcctl.sh add-subnet vpc2 public 10.1.1.0/24
	sudo ./vpcctl.sh nat-enable vpc2 10.1.1.0/24 $(IFACE)
	sudo ./vpcctl.sh peer vpc1 vpc2 10.0.0.0/16 10.1.0.0/16 $(IFACE)

# -----------------------------
# 5️⃣  Run the complete connectivity test suite
# -----------------------------
test:
	@echo "== Intra-VPC connectivity =="; \
	sudo ip netns exec vpc-vpc1-public  ping -c1 -W1 10.200.2.2 | sed 's/^/[vpc1]/' ; \
	sudo ip netns exec vpc-vpc1-private ping -c1 -W1 10.0.1.2 | sed 's/^/[vpc1]/' ; \
	echo "== NAT on public =="; \
	sudo ip netns exec vpc-vpc1-public bash -lc 'curl -sI http://example.com | head -n1' ; \
	echo "== Private no internet (expected fail/timeout) =="; \
	sudo ip netns exec vpc-vpc1-private bash -lc 'timeout 3 curl -sI http://example.com || echo NOINET' ; \
	echo "== Security group check (allow 8080 / deny 22) =="; \
	sudo ip netns exec vpc-vpc1-public  bash -lc 'nohup python3 -m http.server 8080 >/dev/null 2>&1 &' ; sleep 1 ; \
	curl -sI http://10.0.1.2:8080 | head -n1 ; \
	timeout 2 bash -lc 'exec 3<>/dev/tcp/10.0.1.2/22' || echo "PORT22_BLOCKED ✅"

list:
	sudo ./vpcctl.sh list

down:
	sudo ./vpcctl.sh delete vpc2 || true
	sudo ./vpcctl.sh delete vpc1 || true

nuke: down
	@echo "Cleaning residual rules/interfaces..."
	@sudo ip route del 10.0.1.0/24 2>/dev/null || true
	@sudo ip route del 10.200.2.0/24 2>/dev/null || true
	@sudo iptables -t nat -F
	@sudo iptables -F FORWARD
	@sudo iptables -P FORWARD ACCEPT
	@sudo ip netns list | grep '^vpc-' | while read ns; do sudo ip netns del $$ns || true; done
