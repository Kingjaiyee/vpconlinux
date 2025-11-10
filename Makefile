SHELL := /bin/bash

IFACE ?= $(shell ip route show default | awk '/default/{print $$5;exit}')

.PHONY: help
help:
	@echo "Targets: up demo peer test list nat down nuke"

up:
	sudo ./vpcctl.sh create vpc1
	sudo ./vpcctl.sh add-subnet vpc1 public 10.0.1.0/24
	sudo ./vpcctl.sh add-subnet vpc1 private 10.0.2.0/24

nat:
	sudo ./vpcctl.sh nat-enable vpc1 10.0.1.0/24 $(IFACE)

policy:
	sudo ./vpcctl.sh policy-apply vpc1 public policies/public-allow80-deny22.json

peer:
	sudo ./vpcctl.sh create vpc2
	sudo ./vpcctl.sh add-subnet vpc2 public 10.1.1.0/24
	sudo ./vpcctl.sh nat-enable vpc2 10.1.1.0/24 $(IFACE)
	sudo ./vpcctl.sh peer vpc1 vpc2 10.0.0.0/16 10.1.0.0/16 $(IFACE)

test:
	@echo "== Intra-VPC connectivity =="; \
	sudo ip netns exec vpc-vpc1-public  ping -c1 -W1 10.0.2.2 | sed 's/^/[vpc1]/' ; \
	sudo ip netns exec vpc-vpc1-private ping -c1 -W1 10.0.1.2 | sed 's/^/[vpc1]/' ; \
	echo "== NAT on public =="; \
	sudo ip netns exec vpc-vpc1-public bash -lc 'curl -sI http://example.com | head -n1' ; \
	echo "== Private no internet (expected fail/timeout) =="; \
	sudo ip netns exec vpc-vpc1-private bash -lc 'timeout 3 curl -sI http://example.com || echo NOINET' ; \
	echo "== Security group check (allow 80 / deny 22) =="; \
	sudo ip netns exec vpc-vpc1-public bash -lc 'nohup python3 -m http.server 80 >/dev/null 2>&1 &' ; sleep 1 ; \
	sudo ip netns exec vpc-vpc1-private curl -sI http://10.0.1.2:80 | head -n1 ; \
	sudo ip netns exec vpc-vpc1-private bash -lc 'timeout 2 bash -c "</dev/tcp/10.0.1.2/22" && echo BAD || echo PORT22_BLOCKED'

list:
	sudo ./vpcctl.sh list

down:
	sudo ./vpcctl.sh delete vpc2 || true
	sudo ./vpcctl.sh delete vpc1 || true

nuke: down
	@echo "Remove common MASQUERADE rules manually if you added extras:"
	@sudo iptables -t nat -S | nl
