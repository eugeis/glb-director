#!/bin/bash
# Start the REAL DPDK glb-director in pcap-dumper mode on a veth, so it classifies
# + encapsulates the traffic from generate_traffic.py and emits statsd metrics for
# the monitoring stack. This is the director half of the monitoring demo.
#
# It reuses the same build/runtime the smoke test uses (bionic DPDK 17.11, the
# built director + CLI, the lab venv). Dumper mode (TX -> pcap file) sidesteps the
# lab's wire-TX quirk and is exactly what the smoke test verifies.
#
# Requires: the director + CLI built (lab/build.sh), >=1024 free 2MB hugepages,
# the lab venv. The monitoring stack running (start_monitoring.sh) so statsd has a
# listener on STATS_D_PORT.
set -uo pipefail

REPO="$HOME/dev/_forks/glb-director"
D="$HOME/dev/glb-build/dpdk17"
L="$D/usr/share/dpdk/x86_64-default-linuxapp-gcc/lib"
BIN="$REPO/src/glb-director/build/glb-director"
CLI="$REPO/src/glb-director/cli/glb-director-cli"
PY="$HOME/dev/glb-lab-venv/bin/python"
RUN="$HOME/dev/glb-monitor/run"; mkdir -p "$RUN"
STATS_D_PORT="${STATS_D_PORT:-28125}"
GRAF_PORT="${GRAF_PORT:-3002}"
VETH=glbt_dpdk; VETH_PEER=glbt_py

for f in "$BIN" "$CLI" "$PY"; do
  [ -e "$f" ] || { echo "missing: $f (build first: lab/build.sh)"; exit 1; }
done

# --- pre-flight: hugepages + stale EAL state ---------------------------------
sudo rm -f /dev/hugepages/rtemap_*
FREE_HP=$(awk '/HugePages_Free/ {print $2}' /proc/meminfo)
if [ "$FREE_HP" -lt 1024 ]; then
  echo "need >=1024 free 2MB hugepages, have $FREE_HP"
  echo "sudo sh -c 'echo 0 > /proc/sys/vm/nr_hugepages; echo 1024 > /proc/sys/vm/nr_hugepages'"
  exit 1
fi
echo "hugepages free: $FREE_HP"

# --- veth pair (idempotent) ---------------------------------------------------
if ! ip link show "$VETH" >/dev/null 2>&1; then
  sudo ip link add "$VETH" type veth peer name "$VETH_PEER"
fi
sudo ip link set "$VETH" up; sudo ip link set "$VETH_PEER" up
PYMAC=$(cat /sys/class/net/$VETH_PEER/address)
DPDKMAC=$(cat /sys/class/net/$VETH/address)
echo "veth up; $VETH_PEER MAC=$PYMAC  $VETH MAC=$DPDKMAC"

# --- forwarding table (2 active backends) + config ----------------------------
T="$RUN/monitor"; mkdir -p "$T"
cat > "$T/table.json" <<EOF
{
  "tables": [{
    "name": "monitor",
    "hash_key": "12345678901234561234567890123456",
    "seed": "34567890123456783456789012345678",
    "binds": [{ "ip": "10.0.0.1", "proto": "tcp", "port": 80 }],
    "backends": [
      { "ip": "192.168.100.20", "state": "active", "healthy": true },
      { "ip": "192.168.100.21", "state": "active", "healthy": true }
    ]
  }]
}
EOF
cat > "$T/config.json" <<EOF
{
  "outbound_gateway_mac": "$PYMAC",
  "outbound_src_ip": "65.65.65.65",
  "forward_icmp_ping_responses": true,
  "num_worker_queues": 1,
  "flow_paths": [ { "rx_port": 0, "rx_queue": 0, "tx_port": 0, "tx_queue": 0 } ],
  "lcores": {
    "lcore-1": { "rx": true, "tx": true, "flow_paths": [0], "dist": true, "num_dist_workers": 1 },
    "lcore-2": { "work": true, "work_source": 1 }
  },
  "statsd_port": $STATS_D_PORT
}
EOF
"$CLI" build-config "$T/table.json" "$T/fwd.bin"
echo "table + config written to $T (statsd_port=$STATS_D_PORT)"

# --- already running? ---------------------------------------------------------
if pgrep -x glb-director >/dev/null 2>&1; then
  echo "glb-director already running (pid $(pgrep -x glb-director | head -1)); leaving it."
  echo "re-run generate_traffic.py to send traffic."
  exit 0
fi

# --- start the real director (dumper mode: RX veth, TX -> pcap file) ---------
sudo bash -c "LD_LIBRARY_PATH='$L' exec '$BIN' \
  -c 0x7 \
  --socket-mem=832,0 \
  --vdev=eth_pcap0,rx_iface=$VETH,tx_pcap=$T/monitor_tx.pcap \
  -- \
  --debug \
  --config-file '$T/config.json' \
  --forwarding-table '$T/fwd.bin'" > "$T/director.log" 2>&1 &

for i in $(seq 1 30); do
  pgrep -x glb-director >/dev/null 2>&1 && break
  sleep 1
done
DPID=$(pgrep -x glb-director | head -1)
if [ -z "$DPID" ]; then
  echo "!!! director never came up (log below) !!!"; tail -40 "$T/director.log"; exit 1
fi
echo "director pid: $DPID (log: $T/director.log)"
echo "$DPID" > "$RUN/director.pid"

for i in $(seq 1 30); do
  grep -q "running processor_rx_dist_tx" "$T/director.log" 2>/dev/null && break
  pgrep -x glb-director >/dev/null 2>&1 || { echo "!!! director died (log below) !!!"; tail -40 "$T/director.log"; exit 1; }
  sleep 1
done
grep -q "running processor_rx_dist_tx" "$T/director.log" 2>/dev/null \
  || { echo "!!! datapath lcores did not come up in 30s (log below) !!!"; tail -40 "$T/director.log"; exit 1; }
echo "director datapath is up."

echo ""
echo "director is live. Now send traffic (in another terminal):"
echo ""
echo "  sudo $PY $REPO/lab/monitoring/generate_traffic.py \\"
echo "      --iface $VETH_PEER --dst-mac $DPDKMAC --src-mac $PYMAC \\"
echo "      --src 10.11.12.13 --dst 10.0.0.1 --sport 45678 --dport 80 \\"
echo "      --rate 200 --duration 600"
echo ""
echo "then watch:  http://localhost:$GRAF_PORT  (Grafana -> 'GLB Director - datapath & failover')"
echo "to see a failover:  $REPO/lab/monitoring/trigger_drain.sh"
