#!/bin/bash
# Tear down the lab topology (reverse of setup_topology.sh).
# Run stop_services.sh first if the services are up.
set -uo pipefail

for p in proxy1 proxy2; do
    sudo ip netns exec ns-$p ip fou del port 19523 2>/dev/null || true
done
for ns in ns-client ns-director ns-proxy1 ns-proxy2; do
    sudo ip netns del "$ns" 2>/dev/null || true
done
sudo ip link del br0 2>/dev/null || true
sudo ip route del 192.168.100.0/24 dev br0 2>/dev/null || true

echo "topology torn down"
