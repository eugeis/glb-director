#!/bin/bash
# Smoke-test the REAL DPDK glb-director binary end-to-end against a veth pair.
#
# Covers:
#   Phase 1 (encap) : a bind-matching client packet is captured on the veth,
#                     classified, and encapsulated into GLB-GUE. We assert the
#                     full wire format: outer src/dst MAC+IP, the siphash UDP
#                     source port, GUE private data (hops), and the inner packet.
#   Phase 2 (drain) : the flow's primary backend is marked `draining`, the table
#                     is rebuilt (glb-director-cli build-config) and hot-reloaded
#                     via SIGUSR1 (the same signal `systemctl reload` sends in
#                     production). We assert the flow now encapsulates to the
#                     former secondary, with the drained backend as GUE fallback.
#
# Verification strategy: the director runs the eth_pcap vdev in
# `rx_iface=<veth>,tx_pcap=<file>` (dumper) mode. RX is the real veth; TX is
# written to a pcap file that we parse with scapy. This is used because the
# director's wire TX via pcap_sendpacket inside an EAL process does not reach
# the peer veth end on this lab host (characterized in LEARNING.md, "pcap PMD
# TX quirk") -- while the dumper captures byte-for-byte exactly what the
# director encapsulates, which is the glb-director logic under test.
#
# Requires: built glb-director + glb-director-cli (see lab/build.sh),
# hugepages (1024 x 2MB), and the lab venv (~/dev/glb-lab-venv) with
# scapy + siphash + netaddr. Runs with sudo (CAP_NET_RAW for eth_pcap).
set -uo pipefail

REPO="$HOME/dev/_forks/glb-director"
D="$HOME/dev/glb-build/dpdk17"
L="$D/usr/share/dpdk/x86_64-default-linuxapp-gcc/lib"
BIN="$REPO/src/glb-director/build/glb-director"
CLI="$REPO/src/glb-director/cli/glb-director-cli"
PY="$HOME/dev/glb-lab-venv/bin/python"
T="/tmp/glb-smoke"; rm -rf "$T"; mkdir -p "$T"

# test flow (mirrors src/glb-director/tests/test_director_classify_v4.py)
SRC_IP="10.11.12.13"; SRC_PORT=45678; DST_IP="10.0.0.1"; DST_PORT=80
# backends in the lab forwarding table
BE1="192.168.100.20"; BE2="192.168.100.21"

echo "binary:  $BIN"
echo "table:   cli $CLI"
for f in "$BIN" "$CLI" "$PY"; do
    [ -e "$f" ] || { echo "missing: $f (build first: lab/build.sh)"; exit 1; }
done

# --- pre-flight: hugepages + stale EAL state --------------------------------
sudo rm -f /dev/hugepages/rtemap_*
FREE_HP=$(awk '/HugePages_Free/ {print $2}' /proc/meminfo)
if [ "$FREE_HP" -lt 1024 ]; then
    echo "need >=1024 free 2MB hugepages, have $FREE_HP"
    echo "sudo sh -c 'echo 0 > /proc/sys/vm/nr_hugepages; echo 1024 > /proc/sys/vm/nr_hugepages'"
    exit 1
fi
echo "hugepages free: $FREE_HP"

# --- veth pair ---------------------------------------------------------------
sudo ip link del glbt_dpdk 2>/dev/null || true
sudo ip link add glbt_dpdk type veth peer name glbt_py
sudo ip link set glbt_dpdk up
sudo ip link set glbt_py up
PYMAC=$(cat /sys/class/net/glbt_py/address)
DPDKMAC=$(cat /sys/class/net/glbt_dpdk/address)
echo "veth up; glbt_py MAC=$PYMAC glbt_dpdk MAC=$DPDKMAC"

DPID=""
# The director runs as root (CAP_NET_RAW), so all signals to it go through sudo.
# DPID holds the *actual* glb-director pid (found via pgrep), not the sudo
# wrapper's pid -- signalling the wrapper would not reach the exec'd child and
# would leave rtemap_* files pinning the hugepage pool.
director_alive() { pgrep -x glb-director >/dev/null 2>&1; }
cleanup() {
    if [ -n "$DPID" ]; then
        sudo kill "$DPID" 2>/dev/null || true
        sleep 1
        sudo kill -9 "$DPID" 2>/dev/null || true
    fi
    sudo pkill -x glb-director 2>/dev/null || true
    sudo ip link del glbt_dpdk 2>/dev/null || true
    sudo rm -f /dev/hugepages/rtemap_*
}
trap cleanup EXIT

# --- director config (kni intentionally OFF: no rte_kni on this kernel) ------
cat > "$T/config.json" <<EOF
{
  "outbound_gateway_mac": "$PYMAC",
  "outbound_src_ip": "65.65.65.65",
  "forward_icmp_ping_responses": true,
  "num_worker_queues": 1,
  "flow_paths": [
    { "rx_port": 0, "rx_queue": 0, "tx_port": 0, "tx_queue": 0 }
  ],
  "lcores": {
    "lcore-1": {
      "rx": true, "tx": true, "flow_paths": [0],
      "dist": true, "num_dist_workers": 1
    },
    "lcore-2": {
      "work": true, "work_source": 1
    }
  },
  "statsd_port": 8125
}
EOF

# --- tables + expectations ----------------------------------------------------
# Python (repo reference code) computes the rendezvous primary/secondary for the
# test flow and the expected siphash UDP sport, and writes both table variants
# (healthy / primary-draining) plus per-phase expectation files.
"$PY" - "$T" "$SRC_IP" "$SRC_PORT" "$DST_IP" "$DST_PORT" "$BE1" "$BE2" <<'PYEOF'
import json, socket, struct, sys
T, SRC_IP, SRC_PORT, DST_IP, DST_PORT, BE1, BE2 = sys.argv[1:8]
SRC_PORT = int(SRC_PORT); DST_PORT = int(DST_PORT)

sys.path.insert(0, "/home/z000ru5y/dev/_forks/glb-director/src/glb-director/tests")
from rendezvous_table import GLBRendezvousTable
import siphash

HASH_KEY = bytes.fromhex("12345678901234561234567890123456")
SEED     = bytes.fromhex("34567890123456783456789012345678")

def table_json(state1, state2):
    return {
        "tables": [{
            "name": "smoke",
            "hash_key": "12345678901234561234567890123456",
            "seed": "34567890123456783456789012345678",
            "binds": [{"ip": DST_IP, "proto": "tcp", "port": DST_PORT}],
            "backends": [
                {"ip": BE1, "state": state1, "healthy": True},
                {"ip": BE2, "state": state2, "healthy": True},
            ],
        }]
    }

# default hash fields: source address only (glb_director_config.c defaults)
pkt_hash = struct.unpack('<Q', siphash.SipHash_2_4(
    HASH_KEY, socket.inet_pton(socket.AF_INET, SRC_IP)).digest())[0]
row = pkt_hash & 0xffff
ranked = GLBRendezvousTable(SEED).forwarding_table_entry(row, [BE1, BE2])
primary, secondary = ranked[0], ranked[1]
sport = 0x8000 | ((pkt_hash ^ SRC_PORT) & 0x7fff)
print(f"flow {SRC_IP}:{SRC_PORT} -> {DST_IP}:{DST_PORT}: "
      f"row={row} primary={primary} secondary={secondary} sport={sport}")

with open(f"{T}/fwd_healthy.json", "w") as f:
    json.dump(table_json("active", "active"), f, indent=2)
# drain the flow's primary: state=draining -> GLB_BACKEND_STATE_DRAINING_INACTIVE
# in cli/main.c, triggering the primary/secondary swap at build time.
drain = {primary: "draining", secondary: "active"}
with open(f"{T}/fwd_drain.json", "w") as f:
    json.dump(table_json(drain[BE1], drain[BE2]), f, indent=2)

inner = {"inner_src": SRC_IP, "inner_dst": DST_IP,
         "inner_sport": SRC_PORT, "inner_dport": DST_PORT}
with open(f"{T}/expect_p1.json", "w") as f:
    json.dump({"outer_dst": primary, "hops": [secondary], "sport": sport, **inner}, f)
with open(f"{T}/expect_p2.json", "w") as f:
    json.dump({"outer_dst": secondary, "hops": [primary], "sport": sport, **inner}, f)
PYEOF

build_table() { # $1 = json, writes $T/fwd.bin (the path the director watches)
    "$CLI" build-config "$1" "$T/fwd.bin"
}
build_table "$T/fwd_healthy.json"

# --- start the real director (dumper mode: RX veth, TX -> pcap file) ---------
sudo bash -c "LD_LIBRARY_PATH='$L' exec '$BIN' \
  -c 0x7 \
  --socket-mem=832,0 \
  --vdev=eth_pcap0,rx_iface=glbt_dpdk,tx_pcap=$T/tx_dump.pcap \
  -- \
  --debug \
  --config-file '$T/config.json' \
  --forwarding-table '$T/fwd.bin'" > "$T/director.log" 2>&1 &

for i in $(seq 1 20); do
    DPID=$(pgrep -x glb-director | head -1)
    [ -n "$DPID" ] && break
    sleep 0.5
done
[ -n "$DPID" ] || { echo "!!! director process never appeared (log below) !!!"; tail -40 "$T/director.log"; exit 1; }
echo "director pid: $DPID (log: $T/director.log)"

log_grep() { grep -q "$1" "$T/director.log" 2>/dev/null; }

for i in $(seq 1 30); do
    log_grep "running processor_rx_dist_tx" && log_grep "running processor_worker" && break
    if ! director_alive; then
        echo "!!! DIRECTOR DIED during startup (log below) !!!"
        tail -40 "$T/director.log"
        exit 1
    fi
    sleep 1
done
if ! log_grep "running processor_rx_dist_tx"; then
    echo "!!! datapath lcores did not come up within 30s (log below) !!!"
    tail -40 "$T/director.log"
    exit 1
fi
echo "director datapath is up (rx_dist_tx + worker lcores running)."

send_test_packet() {
    sudo "$PY" - "$DPDKMAC" "$PYMAC" "$SRC_IP" "$DST_IP" "$SRC_PORT" "$DST_PORT" <<'PYEOF'
import sys
from scapy.all import Ether, IP, TCP, sendp
DPDKMAC, PYMAC, SRC_IP, DST_IP, SRC_PORT, DST_PORT = sys.argv[1:7]
pkt = (Ether(dst=DPDKMAC, src=PYMAC)
       / IP(src=SRC_IP, dst=DST_IP)
       / TCP(sport=int(SRC_PORT), dport=int(DST_PORT), flags="S")
       / b"glb-smoke")
sendp(pkt, iface="glbt_py", verbose=False)
print("sent:", pkt.summary())
PYEOF
}

validate_phase() { # $1 = phase (1|2)
    local PHASE="$1"
    sleep 2   # let the busy-poll lcore finish encap + dumper flush
    sudo "$PY" - "$T" "$PHASE" "$PYMAC" <<'PYEOF'
import json, os, sys
from scapy.all import Ether, IP, UDP, TCP, rdpcap

T, PHASE, PYMAC = sys.argv[1:4]
sys.path.insert(0, "/home/z000ru5y/dev/_forks/glb-director/src/scapy-glb-gue")
from glb_scapy import GLBGUE  # binds UDP/19523 -> GLBGUE -> inner IP/IPv6

dump = f"{T}/tx_dump.pcap"
if not os.path.exists(dump):
    print(f"FAIL: dump file {dump} does not exist (director TX'd nothing)")
    sys.exit(1)
exp = json.load(open(f"{T}/expect_p{PHASE}.json"))
pkts = []
for p in rdpcap(dump):
    ip = p.getlayer(IP)
    if ip is None or ip.src != "65.65.65.65":
        continue
    udp = p.getlayer(UDP)
    if udp is None or udp.dport != 19523:
        continue
    pkts.append(p)

print(f"phase {PHASE}: {len(pkts)} GLB-GUE packet(s) in dump; expected outer_dst={exp['outer_dst']} hops={exp['hops']} sport={exp['sport']}")
if not pkts:
    print(f"FAIL: no GLB-GUE packet captured in phase {PHASE}")
    sys.exit(1)
p = pkts[0] if PHASE == "1" else pkts[-1]

ip, udp, gue = p[IP], p[UDP], p[GLBGUE]
inner_ip, inner_tcp = gue[IP], gue[IP][TCP]
checks = [
    ("outer ether dst",  p[Ether].dst,          PYMAC),
    ("outer IP src",     ip.src,                "65.65.65.65"),
    ("outer IP dst",     ip.dst,                exp["outer_dst"]),
    ("UDP sport",        udp.sport,             exp["sport"]),
    ("UDP dport",        udp.dport,             19523),
    ("GUE protocol",     gue.protocol,          4),  # PDNET_IP_PROTO_IPIPV4 (inner IP version)
    ("GUE hop_count",    gue.private_data[0].hop_count, 1),
    ("GUE next_hop",     gue.private_data[0].next_hop,  0),
    ("GUE hops",         gue.private_data[0].hops,      exp["hops"]),
    ("inner IP src",     inner_ip.src,          exp["inner_src"]),
    ("inner IP dst",     inner_ip.dst,          exp["inner_dst"]),
    ("inner TCP sport",  inner_tcp.sport,       exp["inner_sport"]),
    ("inner TCP dport",  inner_tcp.dport,       exp["inner_dport"]),
    ("inner payload",    bytes(inner_tcp.payload), b"glb-smoke"),
]
ok = True
for name, got, want in checks:
    status = "ok" if got == want else f"MISMATCH (want {want!r})"
    if got != want:
        ok = False
    print(f"  {name:16s} = {got!r:24s} {status}")
print(f"phase {PHASE}: " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PYEOF
}

# --- Phase 1: encap -----------------------------------------------------------
echo ""
echo "==================== PHASE 1: encap ===================="
send_test_packet
validate_phase 1
RC1=$?
echo "phase 1 rc=$RC1"

# --- Phase 2: drain the flow's primary, hot-reload via SIGUSR1 ----------------
echo ""
echo "==================== PHASE 2: drain ===================="
build_table "$T/fwd_drain.json"
echo "table rebuilt (primary draining); sending SIGUSR1 to $DPID"
sudo kill -USR1 "$DPID"
for i in $(seq 1 10); do
    log_grep "Reload requested" && break
    sleep 1
done
log_grep "Reload requested" || { echo "FAIL: director never logged the reload"; exit 1; }
sleep 2   # workers consume the GLB_CONTROL_MSG_RELOAD_CONFIG ring message
send_test_packet
validate_phase 2
RC2=$?
echo "phase 2 rc=$RC2"

echo ""
echo "==================== director log (tail) ===================="
tail -25 "$T/director.log"
echo "================================================================"

if [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ]; then
    echo "SMOKE TEST: PASS (encap + drain verified against the real DPDK director)"
    exit 0
else
    echo "SMOKE TEST: FAIL (phase1=$RC1 phase2=$RC2; dump: $T/tx_dump.pcap, log: $T/director.log)"
    exit 1
fi
