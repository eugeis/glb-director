#!/bin/bash
# Start the lab services: L7 servers in both proxy namespaces + the lab
# director in the director namespace.
#
# Prereqs: setup_topology.sh has run, lab/live_director + lab/forwarding_table.bin
# are built (build.sh, make_table.sh).
set -uo pipefail
cd "$(dirname "$0")"

# 1. L7 servers bound to the VIP inside each proxy namespace
for p in proxy1 proxy2; do
    if sudo ip netns exec ns-$p pgrep -f "proxy_server.py" >/dev/null 2>&1; then
        echo "  ns-$p: proxy_server already running"
        continue
    fi
    sudo ip netns exec ns-$p nohup python3 "$(pwd)/proxy_server.py" \
        --bind 10.0.0.1 --port 80 --name "$p" \
        >> "$(pwd)/${p}_server.log" 2>&1 &
    echo "  ns-$p: started proxy_server (log: ${p}_server.log)"
done

# 2. the lab director on the director namespace's veth
if sudo ip netns exec ns-director pgrep -x live_director >/dev/null 2>&1; then
    echo "  ns-director: live_director already running"
else
    sudo ip netns exec ns-director nohup "$(pwd)/live_director" \
        -c "$(pwd)/director.conf" \
        -t "$(pwd)/forwarding_table.bin" \
        -i veth-director \
        -s "$(pwd)/director_stats.txt" \
        >> "$(pwd)/director.log" 2>&1 &
    echo "  ns-director: started live_director (log: director.log)"
fi

sleep 1
echo ""
echo "services up. Try:"
echo "  sudo ip netns exec ns-client curl -s http://10.0.0.1/"
