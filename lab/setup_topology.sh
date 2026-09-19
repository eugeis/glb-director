#!/bin/bash
# Build the GLB lab topology on this host.
#
#                      root netns = "ToR switch + router"
#                          br0 + route 192.168.100.0/24 dev br0
#        +----------------+----------------+----------------+
#        |                |                |                |
#   ns-client        ns-director       ns-proxy1        ns-proxy2
#   .10 (+.11-.14)    .20               .31              .32
#
# - The client reaches VIP 10.0.0.1 only through the director's IP.
# - The director's veth stays kernel-owned; the lab director captures on it.
# - GUE frames from the director are addressed to br0's own MAC; the root
#   netns then does L3 delivery to the right proxy (exactly how a real ToR
#   switch would handle a frame sent to its own MAC).
# - Each proxy decapsulates GUE (port 19523) via the kernel `fou` module and
#   owns the VIP on tunl0 (Direct Server Return for the response).
#
# Requires: sudo (no password), kernel module ipt_GLBREDIRECT.ko already
# insmod'ed (see docs/learning/04-lab-setup.md), libxt_GLBREDIRECT.so in
# xtables' lib dir.
set -euo pipefail

CIDR=192.168.100.0/24
VIP=10.0.0.1
GUE_PORT=19523

# --- refuse to clobber an existing br0 that has ports -----------------------
if ip link show br0 >/dev/null 2>&1; then
    ports=$(ls /sys/class/net/br0/brif 2>/dev/null | wc -l)
    if [ "$ports" -gt 0 ]; then
        echo "ERROR: br0 exists and has $ports ports; refusing to delete it." >&2
        exit 1
    fi
    sudo ip link del br0
fi

# --- clean slate (idempotent) ------------------------------------------------
for ns in ns-client ns-director ns-proxy1 ns-proxy2; do
    sudo ip netns del "$ns" 2>/dev/null || true
done

# --- 1. host (root netns) forwarding: it is the lab's little router ---------
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv4.conf.all.rp_filter=0
sudo sysctl -w net.ipv4.conf.default.rp_filter=0

# --- 2. namespaces + bridge ---------------------------------------------------
for ns in ns-client ns-director ns-proxy1 ns-proxy2; do
    sudo ip netns add "$ns"
done
sudo ip link add br0 type bridge
sudo ip link set br0 up

# --- 3. veth pairs -------------------------------------------------------------
for node in client director proxy1 proxy2; do
    sudo ip link add "veth-${node}" type veth peer name "veth-${node}-br"
    sudo ip link set "veth-${node}" netns "ns-${node}"
    sudo ip link set "veth-${node}-br" master br0
    sudo ip link set "veth-${node}-br" up
    sudo ip netns exec "ns-${node}" ip link set lo up
    sudo ip netns exec "ns-${node}" ip link set "veth-${node}" up
done

# --- 4. addresses ---------------------------------------------------------------
sudo ip netns exec ns-client ip addr add 192.168.100.10/24 dev veth-client
# extra client IPs: same director, different source IP -> different hash
for i in 11 12 13 14; do
    sudo ip netns exec ns-client ip addr add 192.168.100.${i}/32 dev veth-client
done
sudo ip netns exec ns-director ip addr add 192.168.100.20/24 dev veth-director
sudo ip netns exec ns-proxy1 ip addr add 192.168.100.31/24 dev veth-proxy1
sudo ip netns exec ns-proxy2 ip addr add 192.168.100.32/24 dev veth-proxy2

# --- 5. root netns routes the lab subnet via the bridge ------------------------
sudo ip route replace "$CIDR" dev br0
sudo sysctl -w net.ipv4.conf.br0.rp_filter=0

# --- 6. client: VIP reachable only via the director -----------------------------
sudo ip netns exec ns-client ip route add "${VIP}/32" via 192.168.100.20 dev veth-client
sudo ip netns exec ns-client sysctl -w net.ipv4.conf.all.rp_filter=0

# --- 7. forwarding policy ---------------------------------------------------------
# The director and client never forward; proxies may (needed for the
# GLBREDIRECT "second chance" rewrite-and-reroute path).
sudo ip netns exec ns-director sysctl -w net.ipv4.ip_forward=0
sudo ip netns exec ns-director sysctl -w net.ipv4.conf.all.rp_filter=0
for p in proxy1 proxy2; do
    sudo ip netns exec ns-$p sysctl -w net.ipv4.ip_forward=1
    sudo ip netns exec ns-$p sysctl -w net.ipv4.conf.all.rp_filter=0
done

# --- 8. proxies: GUE decapsulation + VIP on tunl0 ----------------------------------
for p in proxy1 proxy2; do
    sudo ip netns exec ns-$p modprobe fou
    sudo ip netns exec ns-$p ip fou add port "$GUE_PORT" gue
    sudo ip netns exec ns-$p ip link set up dev tunl0
    sudo ip netns exec ns-$p ip addr add "${VIP}/32" dev tunl0
done

# --- 9. proxies: GLB second-chance iptables rules ------------------------------------
for p in proxy1 proxy2; do
    sudo ip netns exec ns-$p iptables -t raw -A INPUT -p udp -m udp --dport "$GUE_PORT" -j CT --notrack
    sudo ip netns exec ns-$p iptables -A INPUT -p udp -m udp --dport "$GUE_PORT" -j GLBREDIRECT
done

echo ""
echo "topology ready"
echo "  br0 MAC: $(cat /sys/class/net/br0/address)   <- goes into director.conf as outbound_gateway_mac"
echo "  ns-client   192.168.100.10 (+.11-.14)  route ${VIP}/32 via 192.168.100.20"
echo "  ns-director 192.168.100.20"
echo "  ns-proxy1   192.168.100.31 + ${VIP}/32 on tunl0"
echo "  ns-proxy2   192.168.100.32 + ${VIP}/32 on tunl0"
