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
