# 07 — Observability: monitoring, visualizing traffic, and watching failover

> You've now understood *what* the director/proxy do
> ([01](./01-networking-fundamentals.md)–[06](./06-kernel-redirect.md)). This file is
> *how you watch it run*: which signals to look at, what the standard toolchain is
> (and why), how to install/set it up in this lab, and how to use it — including how
> to make a **drain/failover** visibly happen on a dashboard. All the configs live in
> [`lab/monitoring/`](../monitoring/).

## 1. The three pillars, applied to a network datapath

| Pillar | What it answers | Source in GLB |
|--------|-----------------|---------------|
| **Metrics** | "What's the health/rate *right now* and *over time*?" | director's **statsd** counters; proxy's `/proc/glb_redirect_stats` |
| **Packet capture** | "What are the *actual packets* on the wire?" | `tcpdump`/`tshark` on the veths/bridge; the director's **pcap dump**; scapy `glb_scapy` |
| **Logs / events** | "What *events* happened (reload, error)?" | the director's log; the GLBREDIRECT procfs counters |

Metrics tell you *something changed*; packet capture tells you *what the packets
look like*; logs/events tell you *why*. You use all three together.

## 2. The director's metrics (statsd) — the signal dictionary

The director (built with `-DSTATSD`) emits **UDP statsd** every second from the
master lcore ([`glb_control_loop.c`](../../src/glb-director/glb_control_loop.c)) to
`127.0.0.1:<statsd_port>` (default **28125**; the smoke test uses **8125**) under the
namespace **`glb_director_ng`**. They're `count` ("c") metrics carrying a
per-interval **delta**. The full set (→ Prometheus names in
[`monitoring/statsd-exporter-mappings.yml`](../monitoring/statsd-exporter-mappings.yml)):

**Per-port (label `port`):**
| Metric | Meaning / what a spike means |
|--------|------------------------------|
| `port.packets.rx` / `.tx` | packets in/out of the DPDK port — your **throughput** |
| `port.bytes.rx` / `.tx` | bytes in/out — your **bandwidth** |
| `port.packets.rx_errors` | bad/corrupt frames arriving |
| `port.packets.rx_missed` | NIC RX ring overflow (overloaded) |
| `port.packets.rx_nombuf` | **mbuf pool exhausted** → drops ([05 §2b](./05-dpdk.md)) |
| `port.packets.tx_errors` | TX failures |

**Per-queue (labels `port`,`queue`):** `queue.packets.rx`, `.rx_errors`, `bytes.rx`,
`packets.tx`, `bytes.tx` — same but per hardware queue (useful if you scale queues).

**Per-core datapath (label `core`), reset each interval:**
| Metric | Meaning / what a spike means |
|--------|------------------------------|
| `core.packets.total` | all packets the lcore saw |
| `core.packets.matched` | **classified OK** (matched a flow) — healthy traffic |
| `core.packets.unmatched` | **classification failures** — packets with no matching flow; rising = table/flow mismatch |
| `core.packets.rx_errors` | RX errors seen by the lcore |
| `core.packets.kni` | packets handed to the kernel (KNI) — e.g. ICMP |
| `core.packets.encap.success` | **successful GLB-GUE encapsulations** |
| `core.packets.encap.failure` | **failed encapsulations** — a rising value is a real fault |
| `core.packets.eth_tx_sent` / `.kni_tx_sent` | encapsulated packets TXed via eth / KNI |
| `core.config_reload_count` | **table reloads** — increments on every `SIGUSR1` (**each drain/failover**) |

> **The three dials to always watch:** `matched` vs `unmatched` (is traffic being
> classified?), `encap.success` vs `encap.failure` (is encapsulation working?), and
> `config_reload_count` (is a drain/failover happening?).

## 3. The proxy's metrics: `/proc/glb_redirect_stats`

On the **proxy** side, the `GLBREDIRECT` kernel module exposes per-CPU counters at
**`/proc/glb_redirect_stats`** ([06 §8](./06-kernel-redirect.md)):

```
total_packets / accepted_syn_packets / accepted_established_packets /
accepted_syn_cookie_packets / forwarded_to_alternate_packets /
forwarded_to_self_packets / accepted_last_resort_packets
```

- `forwarded_to_alternate_packets` climbing on a (new) primary = it's bouncing
  in-flight connections to the draining/failing backend — **failover in action**.
- `accepted_last_resort_packets` > 0 = **the forwarding table is wrong** (a packet
  exhausted its hops without finding its owner).

## 4. The monitoring stack: statsd → statsd-exporter → Prometheus → Grafana

```
   glb-director                statsd-exporter                Prometheus              Grafana
   (DPDK, master lcore)        (bridge: statsd -> prom)       (TSDB + PromQL)         (dashboards)
   emits UDP statsd  -------->  listens :28125,             scrapes :9102,          queries
   to 127.0.0.1:28125           maps names/tags ->           stores time series      :9090, renders
                                 Prometheus metrics :9102     on :9090                on :3002
```

**Why each piece (and why not "just Prometheus"):**
- **statsd** is the director's *native* emission. A tight DPDK loop can't cleanly do
  an HTTP *pull* (Prometheus's model) from inside the hot process; it just **fires a
  fire-and-forget UDP datagram** (zero backpressure, nanoseconds). That's the
  standard choice for data-plane code.
- **statsd-exporter** bridges the *push* (statsd) to the *pull* (Prometheus) world:
  it listens for statsd, and **maps metric names + tags → Prometheus metrics +
  labels** (see the mapping file). It's the glue.
- **Prometheus** is the **time-series database**: it *scrapes* the exporter, stores
  the series, and answers **PromQL** (rate/increase/etc.) — the query language for
  "how fast is X changing."
- **Grafana** is the **visualization** layer: dashboards on top of Prometheus, with
  time-series, stat, and gauge panels, auto-refresh, and alerting.

> **Go/Rust framing:** statsd is an *append-only fire-and-forget log* of counters;
> statsd-exporter is an *adapter* to a queryable store; Prometheus is the *TSDB +
> query engine*; Grafana is the *UI*. It's the same "ingest → store → query → render"
> pipeline you'd build for app metrics, just with a UDP front door.

### "Grafana or something else?"
- **Grafana + Prometheus is the de-facto standard** for exactly this (L4/L7 datapath,
  network, and backend monitoring). It's what you'll meet in the wild, so learning it
  here transfers. **This lab uses it.**
- Alternatives, and when you'd pick them:
  - **VictoriaMetrics / Mimir** — drop-in Prometheus-compatible storage with better
    long-term scale/compression. Same dashboards; swap the TSDB. Overkill for a lab.
  - **Netdata** — all-in-one (agent + storage + UI) that's *extremely* fast to get a
    live view of a host; great for a 5-minute "what's on this box," less for
    custom datapath metrics/dashboards.
  - **Just Prometheus's built-in UI** — enough for ad-hoc **PromQL** without Grafana
    (open `:9090` → *Graph*, paste a query). Useful before the dashboard is wired up.
  - **Plain `curl :9102/metrics`** — the raw exporter output; the fastest way to
    confirm metrics are flowing at all (no UI needed).
- **For packet-level** visualization the tool is **Wireshark/tshark**, not Grafana —
  see §6.

## 5. Install + setup (this lab)

Everything is **lab-local** (no apt, no systemd) under `~/dev/glb-monitor`. The
binaries are downloaded by the setup; the configs live in [`lab/monitoring/`](../monitoring/).

**One-time install** (if not already done): the three tarballs (Prometheus,
statsd-exporter, Grafana OSS) are extracted into:
```
~/dev/glb-monitor/prometheus/prometheus-*.linux-amd64/prometheus
~/dev/glb-monitor/statsd-exporter/statsd_exporter-*.linux-amd64/statsd_exporter  # repo renamed to statsd_exporter (underscore)
~/dev/glb-monitor/grafana/grafana-v*/bin/grafana-server
```
(Download them with the setup; the launcher auto-discovers them by glob, so any
version works.)

**Start the stack:**
```bash
lab/monitoring/start_monitoring.sh
```
It starts all three (each in its own `setsid` session, so they survive the launching
shell exiting), then **auto-provisions** the Prometheus datasource (`uid=glb-prom`)
and **imports the dashboard** ("GLB Director - datapath & failover") via the Grafana
API. Ports: **Grafana :3002** (admin/admin), **Prometheus :9090**, **exporter :9102**,
statsd **UDP :28125**.

> **Grafana port is `:3002`, not the usual `:3000`.** On this lab host the agent
> runtime already holds `:3000`/`:3001`, so the launcher defaults to `:3002`.
> Override with `GRAF_PORT=<free port> lab/monitoring/start_monitoring.sh` if needed.

**Stop the stack:**
```bash
lab/monitoring/stop_monitoring.sh
```

### Accessing it (headless host → your browser)
The host is headless, so **port-forward** over SSH from your laptop:
```bash
ssh -N -L 3002:localhost:3002 -L 9090:localhost:9090 <you>@<lab-host>
```
Then open **http://localhost:3002** (Grafana) and **http://localhost:9090**
(Prometheus). Log in `admin`/`admin`.

## 6. Visualizing the *traffic* (packet capture)

Metrics show rates; to **see the packets** (the GLB-GUE envelopes), capture:

**a) The director's own output (easiest).** The director runs in **pcap-dumper mode**
(TX → a pcap file), so its encapsulated output is already in a file — no live
capture needed:
```bash
# the monitoring director writes here:
#   ~/dev/glb-monitor/run/monitor/monitor_tx.pcap
# the smoke test writes:  /tmp/glb-smoke/tx_dump.pcap
```
Open that `.pcap` in **Wireshark** (on your laptop): Filter `udp.port == 19523`.
Wireshark has a **GUE dissector** and will show the GUE header; the **GLB private
data** (the hop list) is a custom extension, so to read `hops[]`/`hop_count`
precisely, parse with the repo's scapy binding:
```bash
python -c "import sys; sys.path.insert(0,'src/scapy-glb-gue'); from glb_scapy import GLBGUE; from scapy.all import rdpcap; [print(p.summary()) for p in rdpcap('monitor_tx.pcap')]"
```
(→ [04 §9](./04-encapsulation-and-gue.md) for what to look at.)

**b) Live capture on the bridge (the full 4-netns topology).** See GUE frames in
flight and the decapsulated inner packets:
```bash
sudo tcpdump -i br0 -nn -s0 -w /tmp/glb.pcap 'udp port 19523'      # encapsulated, on the ToR
sudo ip netns exec ns-proxy1 tcpdump -i any -nn -s0 'udp port 19523'  # arriving at a proxy
```
`tshark` (the CLI Wireshark) is great for scripted extraction:
```bash
tshark -r /tmp/glb.pcap -Y "udp.port==19523" -T fields \
  -e ip.src -e ip.dst -e udp.sport -e ip.payload
```

## 7. Watching failover / error handling (the money shot)

Tie it all together — make a **drain** happen and *watch it* across metrics + packets:

1. **Start everything:**
   ```bash
   lab/monitoring/start_monitoring.sh                 # stack + dashboard
   lab/monitoring/run_director_for_monitoring.sh      # real DPDK director (dumper)
   sudo ~/dev/glb-lab-venv/bin/python lab/monitoring/generate_traffic.py \
        --iface glbt_py --dst-mac <DPDKMAC> --src-mac <PYMAC> \
        --src 10.11.12.13 --dst 10.0.0.1 --sport 45678 --dport 80 --rate 200 --duration 900
   ```
2. **Watch the baseline** in Grafana: `Port packets/s` rising, `Classification
   success %` ~100, `Encap success %` 100, `Table reloads` = 0.
3. **Trigger a drain:**
   ```bash
   lab/monitoring/trigger_drain.sh     # rebuild table (primary draining) + SIGUSR1
   ```
4. **Observe the failover in the dashboard:**
   - **`Table reloads`** stat **increments by 1** (the `core.config_reload_count`
     counter advanced on the `SIGUSR1` reload) — [03 §7](./03-load-balancing.md).
   - In the **full topology**, on the *new* primary's proxy, `/proc/glb_redirect_stats`
     → `forwarded_to_alternate_packets` climbs (in-flight connections being bounced
     to the draining one) — [06 §8](./06-kernel-redirect.md).
   - **`Encap failures` / `Unmatched`** stay at **0** (the table swap is clean).
   - Capture the pcap around the reload to see the flow's outer dst **flip from the
     old primary to the secondary** ([04](./04-encapsulation-and-gue.md)).
5. **Error-handling dials** to alert on (see `prometheus.yml` for a sample rule):
   - `rate(glb_director_core_packets_encap_failure_total[2m]) > 0` → encapsulation broken.
   - `rate(glb_director_core_packets_unmatched_total[2m])` high → table/flow mismatch.
   - `rate(glb_director_port_packets_rx_nombuf_total[2m]) > 0` → mbuf pool pressure.
   - `accepted_last_resort_packets` (proxy) > 0 → forwarding table wrong.

> **Architect's takeaway:** the whole "did the drain work?" question reduces to
> *one counter* (`config_reload_count`) on the director and *one counter*
> (`forwarded_to_alternate_packets`) on the proxy — because the design keeps the
> stateless table + in-band hops, the observable surface is tiny and unambiguous.

## 8. What you need to run it (checklist)

- **Monitoring stack:** the three binaries in `~/dev/glb-monitor` (auto-installed by
  the setup). No root needed (they bind localhost ports).
- **Director (for real metrics):** built `glb-director` + `glb-director-cli`
  (`lab/build.sh`), **≥1024 free 2MB hugepages**, the bionic DPDK 17.11 SDK + libs,
  the lab venv (`~/dev/glb-lab-venv`) with scapy. The director runs as root
  (`CAP_NET_RAW` for `eth_pcap`).
- **Port match:** the director's `statsd_port` must equal the exporter's listen port
  (`STATS_D_PORT`, default **28125**; the smoke test uses **8125**). The launcher
  helpers keep these consistent.
- **Access:** SSH port-forward for :3002/:9090 (headless host).

## 9. Key takeaways

1. **Metrics** (director statsd + proxy `/proc/glb_redirect_stats`) for *what's
   happening*; **packet capture** (pcap + Wireshark/tshark + scapy `glb_scapy`) for
   *what the packets are*; **logs** for *events*.
2. The three director dials: **matched/unmatched** (classification),
   **encap success/failure** (encapsulation), **config_reload_count** (drain/failover).
3. The standard stack is **statsd → statsd-exporter → Prometheus → Grafana**; it's
   the de-facto choice for datapath monitoring (VictoriaMetrics/Netdata/Prom-UI are
   the alternatives and when).
4. The lab wires it all up in [`lab/monitoring/`](../monitoring/): `start/stop_
   monitoring.sh` (stack + auto dashboard), `run_director_for_monitoring.sh` (real
   director), `generate_traffic.py` (load), `trigger_drain.sh` (watch a failover).
5. **Failover is observable as a single counter tick** (`config_reload_count`) plus
   the proxy's `forwarded_to_alternate_packets` — a small, unambiguous observable
   surface, a direct payoff of the stateless design.
