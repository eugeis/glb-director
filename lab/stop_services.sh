#!/bin/bash
# Stop the lab services (reverse of start_services.sh).
set -uo pipefail

for ns in ns-director ns-proxy1 ns-proxy2; do
    sudo ip netns exec "$ns" pkill -TERM -f "live_director|proxy_server.py" 2>/dev/null || true
done
sleep 1
echo "services stopped"
