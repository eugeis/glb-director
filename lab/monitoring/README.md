# GLB Director — monitoring quick-start

Live metrics + a Grafana dashboard for the datapath (classification, encapsulation,
throughput) and for **failover** (table reloads / drain). Conceptual background:
[`../concepts/07-observability.md`](../concepts/07-observability.md).

Pipeline: **director (statsd) → statsd-exporter → Prometheus → Grafana**.

## Ports

| Service         | Where                     | Notes                              |
|-----------------|---------------------------|------------------------------------|
| Grafana         | `http://localhost:3002`   | `admin`/`admin`; `GRAF_PORT` to override |
| Prometheus      | `http://localhost:9090`   | TSDB + PromQL                      |
| statsd-exporter | `http://localhost:9102/metrics` | raw bridged metrics       |
| statsd (UDP)    | `127.0.0.1:28125`         | where the director emits           |

> Grafana is on **`:3002`** here because the agent runtime holds `:3000`/`:3001` on
> this host. The launcher refuses to start if `GRAF_PORT` is taken (it tells you).

## Prerequisites

- One-time: the three binaries under `~/dev/glb-monitor/` (downloaded by the setup).
- The monitoring stack needs only the venv-free binaries (no root; binds localhost).
- The **director** needs: built `glb-director` + `glb-director-cli` (`lab/build.sh`),
  **≥1024 free 2MB hugepages**, the DPDK 17.11 libs, and the lab venv
  (`~/dev/glb-lab-venv`) with scapy. It runs as root.

## Run it (3 commands, in order)

```bash
# 1. start the stack + auto-provision the datasource + import the dashboard
lab/monitoring/start_monitoring.sh

# 2. start the REAL DPDK director in pcap-dumper mode (creates a veth, loads a table)
lab/monitoring/run_director_for_monitoring.sh

# 3. send traffic at it (the script prints the exact line; ~200 pps, 3 min)
sudo ~/dev/glb-lab-venv/bin/python lab/monitoring/generate_traffic.py \
    --iface glbt_py --dst-mac <glbt_dpdk-mac> --src-mac <glbt_py-mac> \
    --src 10.11.12.13 --dst 10.0.0.1 --sport 45678 --dport 80 --rate 200 --duration 180
```

Step 2 prints the exact step-3 line (with the right MACs) once the datapath is up.
Then open **http://localhost:3002** → dashboard **"GLB Director - datapath & failover"**.

### Traffic options & how much you can push

- **`--flags`** — `S` (default) = SYN (new-flow); **`A` = ACK (established)**. Use
  `--flags A` so a drain re-routes an *existing* connection, not just new SYNs.
- **`--sources 10.11.12.14,10.11.12.15,…`** — more distinct flows; each 5-tuple hashes
  to backend `.20` or `.21`. Watch the split in the pcap (`monitor_tx.pcap`), not a
  single metric (`matched` is *bind-level*: does the flow hit a VIP we serve).
- **How much:** the *director* is real DPDK and **loses nothing** here (0 `rx_missed` /
  `rx_nombuf` at every tested rate) — it is *not* the bottleneck. The **scapy generator
  is**: it's capped at **~300 pps** in this setup (Python 20-packet batch loop +
  `sendp` overhead). Measured achieved RX: req 500→181, 2000→308, 5000→332 pps. To
   stress the datapath higher, use a faster sender (bigger batches / `sendpfast` / a
   raw-socket C sender / `trafgen`) rather than a higher `--rate` on this script. The
   real datapath ceiling (fast C sender) is measured in
   [Throughput: measured ceiling](#throughput-measured-ceiling--what-to-understand) below.

## Throughput: measured ceiling & what to understand

The scapy sender caps at ~300 pps, so it can't stress the datapath. A fast `AF_PACKET`
C sender does. It's [`blast/blast.c`](blast/blast.c) — `gcc -O2 -o blast blast.c` — and
it sends a fully-formed single-IP **TCP** frame (the exact bytes; no kernel IP layer).
Use it two ways:

- **local** (isolate the director): feed the veth peer directly —
  `sudo ./blast glbt_py <secs> <cpu>`.
- **cross-host** (real network, second host): set `DSTMAC`/`SRCMAC` (env) to the real
  NIC MACs and blast the NIC —
  `DSTMAC=<peer-mac> SRCMAC=<this-mac> sudo ./blast <nic> <secs> <cpu>`.

> **Do not use a `SOCK_RAW` sender for the cross-host test.** On this Proxmox path
> raw-socket egress arrives **IP-in-IP wrapped** (an extra outer IP header, proto still
> TCP), so the single-IP classifier misreads the L4 port (it sees the inner IP's length
> field as the dport) → unclassified → KNI → drop. `AF_PACKET` sends your exact bytes,
> so the frames arrive clean and classify normally. (Normal non-raw traffic — e.g. ping
> — is not wrapped; it's specific to raw-socket egress on this path.)

### Measured (director in pcap-dumper mode, 100-byte TCP packets)

| feed (sender cores) | feed rate   | director RX | matched=encap=TX (pcap) | loss |
|---------------------|-------------|-------------|-------------------------|------|
| 1 core              | 790k pps    | 791k        | 791k                    | 0%   |
| 4 cores (feed peak) | 1.61M pps   | **1.54M**   | 1.54M                   | 4% (kernel socket) |
| 12 cores            | 1.09M pps   | 1.09M       | 1.09M                   | 0.3% |

**End-to-end datapath ceiling ≈ 1.54M pps (~1.16 Gbps @ 100B)**, with **zero loss in
classify/encap/TX** (`matched == encap == pcap-records`, exact).

### Cross-host end-to-end (406x → 405x over the real Proxmox network)

405x and 406x are VMs on **different Proxmox hosts**, on the same data-VLAN (L2-adjacent,
~0.26ms RTT). Feed 406x's `blast` (AF_PACKET, `DSTMAC`=405x's NIC MAC) out `ens18`, and
redirect the flow into the director on 405x with a `tc` ingress rule
(`ip dst 10.0.0.1 → mirred redirect glbt_py`). This is a true end-to-end path
(406x virtio → host bridge → switch → 405x virtio → tc → director), measured with the
three latency-free counters (406x `sent`, 405x `/sys/.../rx_packets`, 405x pcap records):

| sender cores | 406x sent | arrived | encap (pcap) | loss (network / encap) |
|--------------|-----------|---------|--------------|------------------------|
| 1            | 102k pps  | 102k    | 102k         | 0% / 0%                |
| 4            | 272k pps  | 272k    | 272k         | 0% / 0%                |
| 8            | 274k pps  | 274k    | 274k         | 0% / 0%                |

**The cross-host path is 100% lossless** (network delivery 0%, director encap 0%), but
the **aggregate plateaus at ~274k pps (~219 Mbps @ 100B)**: that's the **406x virtio NIC
TX ceiling** (shared virtio TX ring — per-core falls 102k → 68k → 34k as cores are added
while aggregate stays ~274k). It's far below the director's ~1.54M pps RX ceiling, so in
the cross-host path **the director is not the bottleneck — the sender's virtio TX is**.
To push the director higher over the network you need a faster sender (bigger virtio ring,
more parallelism, or a real NIC on 406x).

### What matters (the non-obvious parts)

**1. The datapath is a 3-lcore pipeline, not one loop.**
- **core 0** = `main_loop_control`: control plane + statsd (sleeps 1s, flushes metrics
  every ~10s).
- **core 1** = `processor_rx_dist_tx` (workloads RX|DIST|TX): pulls from the NIC,
  **distributes** bursts to the workers via a DPDK `rte_distributor`, then **TX**es the
  returned bursts.
- **core 2** = `processor_worker` (workloads WORK): `rte_distributor_get_pkt` →
  **classify** (`rte_acl`) → **encap** (GLB-GUE) → returns the burst.

Flow: `core1 RX → (distributor) → core2 classify+encap → (returned) → core1 TX`. The
counters are per-core for this reason — RX on `core01`, matched/encap on `core02`, TX
on `core01`. If core 2 ever stops draining, the distributor queue fills and core 1 keeps
RX'ing (counting) but can't forward — so **always cross-check RX vs matched**, not just RX.

**2. The bottleneck is the RX lcore reading the *kernel-capture* veth — a lab artifact,
not the datapath's real limit.** Here the "NIC" is the `eth_pcap0` vdev
(`rx_iface=glbt_dpdk`), which reads from a **kernel AF_PACKET socket on the veth**, not a
NIC-bound DPDK PMD. core 1 pulling from that kernel socket tops out at ~1.54M pps; feed
it more and the *kernel socket* drops the excess (the 4% at 1.61M; `rx_missed` stays 0
because it's dropped at the socket, not a NIC ring). The classify+encap logic is far
faster (it processed 100% of 1.54M with headroom). A real NIC-bound PMD would reach many
Mpps — but this VM's only NIC is its management NIC (no SR-IOV/VF), so that ceiling can't
be measured on this host.

**3. It is genuinely lossless in the datapath.** Up to the RX ceiling,
`matched == encap_success == eth_tx_sent == pcap-records` exactly, and
`rx_missed`/`rx_nombuf`/`rx_errors` stay 0. The *only* loss is at the kernel-socket RX
boundary when the feed exceeds ~1.54M.

**4. Metrics flush every ~10s — measure deltas, not a short `rate()`.** The control core
`sleep(1)`s and emits at `stat_wait>=10`. Port counters are emitted as **deltas**
(exporter accumulates); core counters as **reset-deltas** (read + zero each flush). A
Prometheus `rate()[15s]` sampled mid-burst can read 0. To measure: read the exporter
(`:9102/metrics`) cumulative counters **before/after a burst that spans a flush**, or
count **pcap records** (`blast/pcapcount.py`) — the pcap is written per-packet, so it's
exact and latency-free.

**5. The bind rule is TCP (proto 6) — sending UDP is a trap.** The loaded classifier is
`10.0.0.1:[80-80] (proto: 6)`. UDP packets to :80 classify as **unclassified → KNI →
drop** (they hit `..._core_packets_kni_total`, not `..._matched_total`), which *looks*
like "the pipeline stalled" but isn't. Send **TCP**. (The `no v6 classifier loaded,
dropping packets` line in `director.log` is unrelated — background IPv6/NDP on the veth.)

**6. The single veth caps the *feed*, not the director.** 12 sender cores on one veth
contend on its TX qdisc (each drops from 790k to ~90k), so aggregate peaks at ~1.6M pps
(4 cores) then falls. That's why one 64-core host (director uses 3 cores) is enough to be
both client and server — a second host isn't needed just to reach the director's ceiling.

## Watch a failover

With the director + traffic running, drain the flow's primary backend and reload:

```bash
lab/monitoring/trigger_drain.sh
```

It rebuilds the table with `192.168.100.21` (the flow's primary) `draining` and sends
`SIGUSR1` (the same signal `systemctl reload` sends in production). Watch the
**"Table reloads"** stat tick (metric `glb_director_core_config_reload_total`) and, with
a long-lived connection, the flow re-route to the secondary `.20`. The script prints a
one-liner to restore the healthy table.

## Stop it

```bash
lab/monitoring/stop_monitoring.sh   # stops stack + director + removes the veth
```

## Where things live

- Logs/state/pids: `~/dev/glb-monitor/run/` (`grafana.log`, `prometheus.log`,
  `statsd-exporter.log`, `monitor/director.log`, `*.pid`).
- Director's encapsulated output (dumper mode): `~/dev/glb-monitor/run/monitor/monitor_tx.pcap`.
- Prometheus TSDB: `~/dev/glb-monitor/run/prom-data/`.

## Metrics that matter

- `..._port_packets_rx/tx_total`, `..._port_bytes_rx/tx_total` — throughput (TX bytes >
  RX bytes by the GUE/outer-header overhead, i.e. encapsulation is happening).
- `..._core_packets_matched/unmatched_total` — classification.
- `..._core_packets_encap_success/failure_total` — encapsulation.
- `..._core_config_reload_total` — **failover / table reloads**.
- `..._port_packets_rx_missed/rx_nombuf/rx_errors_total` — RX health (ring overruns).

Full list + mapping: [`statsd-exporter-mappings.yml`](statsd-exporter-mappings.yml).

## Troubleshooting

- **"Grafana port already in use"** — the launcher printed a free one; re-run with
  `GRAF_PORT=<port>`.
- **Director won't start** — `tail ~/dev/glb-monitor/run/monitor/director.log`; usually
  <1024 free hugepages or a stale `/dev/hugepages/rtemap_*` (run step 2 again, it cleans up).
- **No metrics in Grafana but traffic is flowing** — the director's `statsd_port`
  (default `28125`) must equal the exporter's listen port; check
  `curl -s localhost:9102/metrics | grep glb_director`.
- **`no v6 classifier loaded, dropping packets`** in `director.log` is expected noise on
  the veth (background IPv6/NDP); the IPv4 test flow is still classified + encapsulated.
