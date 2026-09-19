# glb-director — hands-on lab notes

This directory is a self-contained lab for running the **real DPDK `glb-director`**
binary on a bare Linux host (no KNI, no container) and verifying its two core
behaviors end-to-end:

1. **Encap** — a bind-matching client packet is classified and encapsulated into
   GLB-GUE with the exact wire format the code produces.
2. **Drain** — the flow's primary backend is marked `draining`, the forwarding
   table is rebuilt and hot-reloaded via `SIGUSR1`, and the flow re-routes to the
   former secondary.

`smoke_dpdk_director.sh` runs both phases and is a **passing** test (see
"Running the lab" below). The rest of the directory (`setup_topology.sh`,
`start_services.sh`, `drain.sh`, `proxy_server.py`, `long_lived_client.py`,
`live_director.c`, …) is a richer 4-netns topology that exercises the same logic
against live proxy servers; the smoke test is the minimal, deterministic core.

---

## 0. Deep-dive concept guides & live monitoring (start here)

This file is the **tour** of what was built and verified. To **learn the concepts
deeply** — the networking, load-balancing, encapsulation, DPDK, and proxy-side
mechanics, each explained from first principles for a **Go/Rust / architecture**
background and linked to the actual source — use the companion guides:

- **Concepts** (index: [`concepts/README.md`](./concepts/README.md)), in order:
  1. [Networking fundamentals](./concepts/01-networking-fundamentals.md) — layers, IP/MAC, ports, CIDR, the 5-tuple flow key, endianness
  2. [Linux virtual networking](./concepts/02-linux-virtual-networking.md) — netns / veth / bridge, the real lab topology, DSR
  3. [Load balancing](./concepts/03-load-balancing.md) — stickiness, rendezvous hashing, primary+secondary, draining, anycast
  4. [Encapsulation & GUE](./concepts/04-encapsulation-and-gue.md) — tunneling, the GLB-GUE byte layout, the encap code path
  5. [DPDK](./concepts/05-dpdk.md) — EAL / hugepages / PMD / lcores / mbuf / KNI / pcap vdev
  6. [The proxy second-chance](./concepts/06-kernel-redirect.md) — netfilter/iptables, `GLBREDIRECT`, the proxy decision
  7. [Observability](./concepts/07-observability.md) — metrics / packet capture / failover + the monitoring how-to
- **Monitoring / visualization** — a **Prometheus + Grafana** stack (installed
  locally, nothing system-wide), a traffic generator, and a drain trigger to **watch
  a failover live** on a dashboard: [`monitoring/`](./monitoring/) — see
  [07-observability](./concepts/07-observability.md) for install, setup, and how to use it.

The sections below (§1–§10) are the **condensed** notes; the `concepts/` guides are
the expanded, from-first-principles versions with source links.

---

## 1. What glb-director is

`glb-director` is the data-plane "director" of a Global Load Balancer (GLB). It
sits in front of a set of **binds** (VIP + protocol + port, e.g.
`10.0.0.1 tcp/80`). When a client packet destined to a bind arrives, the director:

- **classifies** it against the bind set (DPDK ACL),
- **hashes** the flow to pick a **primary** and **secondary** backend
  (rendezvous / consistent hashing over a 65536-row table),
- **encapsulates** the original packet in a GLB-GUE tunnel
  (`Ether / IPv4 / UDP / GUE / <original packet>`), sending it to the primary
  backend with the secondary carried in the GUE hop list as a fallback,
- forwards **unmatched** traffic to a KNI port (or drops it if KNI is disabled).

There are two implementations in the repo: **DPDK** (this lab) and **XDP**. The
DPDK director is a multi-lcore, busy-poll application built on DPDK 17.11.

Components touched by the lab:

| Component | Path | Role |
|---|---|---|
| `glb-director` | `src/glb-director/` | the DPDK datapath (built target) |
| `glb-director-cli` | `src/glb-director/cli/` | `build-config`: JSON → binary forwarding table |
| `glb-hashing` | `src/glb-hashing/` | shared route calc, packet parsing, GUE header |
| `scapy-glb-gue` | `src/scapy-glb-gue/` | scapy layer for parsing GLB-GUE (used by the test) |
| `ipt_GLBREDIRECT` | `src/glb-redirect/` | kernel second-chance redirect (proxy side) |

---

## 2. Lab environment & build path

Host facts (this box):

- Debian 12 **bookworm**, kernel `6.1.0-52-amd64`, 32 cores, single NUMA, ~23 GB RAM.
- User `z000ru5y` (non-root) with passwordless `sudo` (needed for `CAP_NET_RAW`
  and hugepage/veth setup).
- Bookworm's packaged DPDK is **22.11 and meson-only** — the glb-director build
  system uses the legacy `mk/rte.vars.mk` makefiles, which 22.11 no longer ships.

**Resolution:** stage a **bionic DPDK 17.11.1-6** SDK (make-based) and build
against it:

```
~/dev/glb-build/dpdk17/                  # staged DPDK 17.11 SDK
  usr/share/dpdk/                        # RTE_SDK (make includes + rte.extapp.mk)
  usr/share/dpdk/x86_64-default-linuxapp-gcc/lib   # RTE_TARGET runtime libs
```

Build (from `src/glb-director`):

```
make RTE_SDK=$HOME/dev/glb-build/dpdk17/usr/share/dpdk \
     RTE_TARGET=x86_64-default-linuxapp-gcc
```

Runtime needs the DPDK libs on `LD_LIBRARY_PATH`:

```
LD_LIBRARY_PATH=$HOME/dev/glb-build/dpdk17/usr/share/dpdk/x86_64-default-linuxapp-gcc/lib
```

and the PMDs at the EAL-baked-in plugin path
`/usr/lib/x86_64-linux-gnu/dpdk-17.11-drivers/` (install `librte_pmd_pcap.so.17.11`
there — the smoke test only uses the `eth_pcap` vdev).

`glb-director-cli` only needs `libjansson` (no DPDK runtime path required).

---

## 3. Launch contract

The DPDK director takes **EAL args before `--`** and **app args after `--`**:

```
glb-director \
  -c 0x7 \
  --socket-mem=832,0 \
  --vdev=eth_pcap0,rx_iface=glbt_dpdk,tx_pcap=/tmp/glb-smoke/tx_dump.pcap \
  -- \
  --debug \
  --config-file  /tmp/glb-smoke/config.json \
  --forwarding-table /tmp/glb-smoke/fwd.bin
```

Key facts learned:

- **`-c 0x7`** = master lcore 0 + workers on lcores 1 and 2. The config's
  `lcore-1`/`lcore-2` are **physical core IDs**, so the mask must cover them.
- **`--socket-mem=832,0`** is mandatory here. The staged DPDK is built with
  `CONFIG_RTE_MAX_MEMSEG=256`, so the *default* EAL memory reservation (1024
  pages / ~2 GB) fails with
  `EAL: Can only reserve 419 pages from 1024 requested` / `Cannot init memory`.
  832 MB stays under the 419-page (838 MB) cap while covering the mbuf pool
  (below).
- **mbuf pool sizing** (`config.h`): `NB_MBUF = (8192*8)-1 = 65535`,
  `MBUF_DATA_SZ = 9348` → pool ≈ 625 MB. This is why the socket needs ≥ ~650 MB.
- **`kni` is omitted / false.** The director normally exposes unmatched traffic
  on a KNI (`/dev/kni`) interface; there is no usable `rte_kni` for this kernel,
  so the lab runs KNI-less. Unmatched packets are then dropped (and logged).
  Readiness is signaled via `sd_notify(READY=1)` in `main.c`, **not** by a KNI
  interface appearing — so the lab waits on log markers instead (see §9).
- **vdev naming**: in DPDK 17.11 the pcap vdev is `eth_pcap0` (not `net_pcap0`).
  The pcap PMD supports `iface=`, `rx_iface=`, `tx_iface=`, `rx_pcap=`, and
  `tx_pcap=` (verified via `strings` on `librte_pmd_pcap.so.17.11`). The lab uses
  `rx_iface=<veth>,tx_pcap=<file>` (dumper mode) — see §7.

### Director config (`config.json`)

```json
{
  "outbound_gateway_mac": "<peer veth MAC>",   // outer Ether dst (required)
  "outbound_src_ip": "65.65.65.65",            // outer IPv4 src (required)
  "forward_icmp_ping_responses": true,
  "num_worker_queues": 1,
  "flow_paths": [ { "rx_port": 0, "rx_queue": 0, "tx_port": 0, "tx_queue": 0 } ],
  "lcores": {
    "lcore-1": { "rx": true, "tx": true, "flow_paths": [0],
                 "dist": true, "num_dist_workers": 1 },
    "lcore-2": { "work": true, "work_source": 1 }
  },
  "statsd_port": 8125
}
```

- `lcore-1` does **RX + distribute + TX**; `lcore-2` does the **worker** role
  (classify + encap). The master lcore (0) runs the control loop (reload +
  statsd).
- The **outer source MAC** is not configurable: `main.c` fills
  `local_ether_addr` from the port's MAC via `rte_eth_macaddr_get(0, …)`. Only
  the outer **destination** MAC (`outbound_gateway_mac`) is configurable.

---

## 4. Forwarding table & rendezvous hashing

`glb-director-cli build-config <in.json> <out.bin>` converts a JSON table into a
binary table the director loads (magic `GLBD`, fmt v2). Per table it writes:

- backends (`ip`, `state`, `healthy`),
- binds (`ip`, `proto`, `port` or `port_start`/`port_end`, optional CIDR),
- `hash_key` (16 B) and `seed` (16 B),
- **65536 precomputed rows**, each a `(primary_idx, secondary_idx)` pair.

### The rendezvous computation (per row)

For row index `i`:

```
row_seed  = siphash24(seed, htonl(i))                       # 8 bytes
score(be) = siphash24(seed, row_seed || be.ip)              # per backend
rank the backends by score (ascending)
```

The top of the ranking is the **primary**, the next is the **secondary**. This
is exactly mirrored by the repo's own reference implementation
(`src/glb-director/tests/rendezvous_table.py`), which the smoke test imports to
compute *expected* values — so the test cross-checks the director's binary table
against the documented hashing.

### Hash key for a packet

The default hash field is **source address only** (`glb_director_config.c`
defaults: `src_addr=1`, rest `0`). So:

```
pkt_hash  = siphash24(hash_key, src_ip)          # little-endian u64
row       = pkt_hash & 0xffff
flow_hash = src_port (TCP/UDP)                   # "flow hash hint"
```

### The drain swap (the crux of the drain test)

In `cli/main.c`, after ranking a row:

```
primary_bad = (primary.state == DRAINING_INACTIVE) || (primary.health != UP)
if (primary_bad && secondary.state == ACTIVE):
    swap(primary, secondary)
```

State mapping: `active→1`, `filling→0`, `draining→2`, `inactive→2`
(`draining` and `inactive` share the `DRAINING_INACTIVE` code). `state: inactive`
backends are **excluded from the ranking entirely**; `draining` keeps the backend
ranked but marks it "bad" so it loses the primary slot. `healthy: false` also
makes a primary "bad".

> Note: the swap condition compares `secondary.state == GLB_BACKEND_HEALTH_UP`
> (a `state` field tested against the value `1`, which coincides with
> `ACTIVE`). It works, but it's an accidental alias, not a semantic match.

Net effect for a 2-backend table when the flow's **primary** is drained:

- **before:** outer dst = P1, GUE hops = [P2]
- **after:**  outer dst = P2 (promoted), GUE hops = [P1] (now the fallback)

The packet's `sport` is **unchanged** (the hash is deterministic and independent
of backend state) — only the destination and hop list move.

> **Deep dive:** [03-load-balancing](./concepts/03-load-balancing.md) explains *why*
> the table is a precomputed rendezvous ranking, the primary/secondary "second
> chance", the drain state machine, and anycast.

---

## 5. GLB-GUE wire format (byte-verified)

`glb_encapsulate_packet` (`src/glb-director/glb_encap.c`) builds, from the top:

```
Ether
  d_addr = outbound_gateway_mac        (config)
  s_addr = local_ether_addr            (port MAC, main.c)
IPv4
  src    = outbound_src_ip             (config, e.g. 65.65.65.65)
  dst    = primary backend             (hops[0])
  flags  = DF, ttl = default, proto = UDP(17)
UDP
  sport  = 0x8000 | ((pkt_hash ^ flow_hash) & 0x7fff)
  dport  = 19523                       (GLB_GUE_PORT, 'LB'+1)
  cksum  = computed (rte_ipv4_udptcp_cksum)
GUE (struct glb_gue_hdr, packed)
  version_control_hlen : version(2)=0, control(1)=0, hlen(5)=1+remaining_hops
  protocol             : 4 (IPIPV4) or 41 (IPIPV6)   <-- inner IP version, NOT L4
  flags                : 0
  private_type         : 0
  next_hop             : 0
  hop_count            : remaining_hop_count
  hops[]               : the non-primary hops (e.g. [secondary])
<original IP/TCP/... packet, L2 stripped>
```

The **first** hop becomes the outer IP destination and is *removed* from the GUE
hop list; the rest are carried in `hops[]`. For a 2-backend flow: `hop_count=1`,
`hlen=2`, `hops=[secondary]`.

**Gotcha:** the GUE `protocol` byte is the **inner IP version** (4/41), not the
inner L4 protocol. (An early draft of the smoke test asserted `6`/TCP and would
have failed.)

### Concrete verified values (test flow)

For `10.11.12.13:45678 → 10.0.0.1:80`, bind `10.0.0.1 tcp/80`, backends
`192.168.100.20` / `192.168.100.21`:

```
pkt_hash row   = 23741
primary        = 192.168.100.21
secondary      = 192.168.100.20
UDP sport      = 61139
```

The smoke test asserts the full 14-field layout (outer MAC/IP, both UDP ports,
GUE protocol/hop_count/next_hop/hops, and every inner field) and it **passes** in
both phases.

> **Deep dive:** [04-encapsulation-and-gue](./concepts/04-encapsulation-and-gue.md) —
> why GUE-over-UDP, the UDP-sport-as-hash for ECMP/RSS spreading, and the encap
> code path line by line.

---

## 6. Drain / hot reload (SIGUSR1)

The reload path (`src/glb-director/glb_control_loop.c`):

1. `signal_handler` catches `SIGUSR1` → sets `reload_requested` (atomic) and
   bumps `reload_count`.
2. The **master lcore**'s `main_loop_control` (a 1-second poll loop) sees the
   flag, calls `load_glb_fwd_config()` → `create_glb_fwd_config(<the same
   --forwarding-table path from startup>)`, logs `Reload requested`, and
   `enqueue_reload_control_msg()` pushes a `GLB_CONTROL_MSG_RELOAD_CONFIG` to
   **every worker lcore** via their control rings.
3. Worker lcores pick up the message and hot-swap the forwarding config
   (log: `loaded new config`).

So to drain a backend you: **rebuild the table file in place** (the CLI writes
atomically via temp+rename), then **`kill -USR1 <director-pid>`**. No restart.
This is exactly what `systemctl reload glb-director` does in production.

The smoke test's phase 2 confirms: after marking the primary `draining` and
reloading, the same source packet now encapsulates to the **former secondary**
with the drained backend as the GUE fallback, and the log shows the reloaded
config with the backend in `state: 2`.

> The smoke test must signal the **real director PID** (found via
> `pgrep -x glb-director`), not the `sudo` wrapper's `$!`. Signalling the wrapper
> never reaches the `exec`'d child and leaves `rtemap_*` files pinning the
> hugepage pool (see §8).

---

## 7. The pcap PMD TX quirk (lab-specific) and the dumper workaround

**Symptom.** When the director TXs through the `eth_pcap` vdev in single-`iface`
mode, `pcap_sendpacket` returns success but **zero bytes reach the peer veth
end** — the peer's kernel RX counter shows no delta.

**Controls (all ruled out as the cause):**
- Standalone libpcap opening a *fresh* handle delivers the director's exact
  94-byte frame to the peer. ✓
- Concurrent RX+TX on the *same* libpcap handle delivers. ✓
- scapy/AF_PACKET send on the peer delivers. ✓
- So the veth/libpcap/kernel path is healthy — it's specifically the
  **EAL-process pcap TX** that misbehaves on this host (DPDK 17.11 `eth_pcap`
  PMD + this kernel). It is **not** a glb-director logic defect: the bytes the
  director produces are correct (see below).

**Workaround / verification strategy.** Run the vdev in **dumper mode**:

```
--vdev=eth_pcap0,rx_iface=<veth>,tx_pcap=<dump.pcap>
```

RX is the real veth; TX is written to a pcap file instead of the wire. The
director's encapsulated output is captured **byte-for-byte**, which is precisely
the glb-director logic under test. The smoke test parses `tx_dump.pcap` with
scapy (using the repo's `scapy-glb-gue` layer) and asserts the full format.

The upstream test suite (`test_director_classify_v4.py`, etc.) sniffs the wire
directly and **requires `/dev/kni`** (it `SkipTest`s otherwise); it runs in
privileged Docker on Ubuntu focal where KNI loads. The lab demonstrates the same
encap/drain logic on a host **without KNI** and **without relying on wire TX**,
via the dumper.

---

## 8. Hugepage & EAL gotchas (and the PID pitfall)

- **Stale `rtemap_*` files pin hugepages.** Even after the director dies,
  `/dev/hugepages/rtemap_*` files can keep pages allocated so `HugePages_Free`
  stays low. `rm -f /dev/hugepages/rtemap_*` before (and after) each run.
- **`CONFIG_RTE_MAX_MEMSEG=256`** caps the default EAL reservation; always pass
  `--socket-mem=<MB>,0` (the lab uses `832,0`).
- **Signal the real PID.** Launching via `sudo bash -c "exec …"` makes `$!` the
  *sudo* wrapper's PID. An unprivileged `kill` can't signal the root-owned
  child anyway. Track the real PID with `pgrep -x glb-director` and use
  `sudo kill …`. Missing this is what originally left `rtemap_*` files behind.
- **Readiness without KNI:** wait for the datapath log markers
  (`running processor_rx_dist_tx` and `running processor_worker`) rather than a
  KNI interface.

---

## 9. Running the lab

Prereqs (one-time):

- Built `glb-director` + `glb-director-cli` (see §2) at
  `src/glb-director/build/glb-director` and `src/glb-director/cli/glb-director-cli`.
- Hugepages: `sudo sh -c 'echo 1024 > /proc/sys/vm/nr_hugepages'` (2 MB pages,
  mounted at `/dev/hugepages` + `/mnt/huge`).
- `librte_pmd_pcap.so.17.11` in `/usr/lib/x86_64-linux-gnu/dpdk-17.11-drivers/`.
- A lab venv with `scapy`, `siphash`, `netaddr`:
  `~/dev/glb-lab-venv` (created from the repo's `requirements.txt`).

Run (needs sudo):

```
bash lab/smoke_dpdk_director.sh
```

Expected output ends with:

```
phase 1: PASS
phase 2: PASS
SMOKE TEST: PASS (encap + drain verified against the real DPDK director)
```

Artifacts are left in `/tmp/glb-smoke/` for inspection: `tx_dump.pcap`
(the director's TX), `director.log`, and the generated table/expectation files.

### The richer topology (optional)

`setup_topology.sh` builds 4 netns (`ns-client` / `ns-director` / `ns-proxy1` /
`ns-proxy2`) behind a bridge, `make_table.sh` + `drain.sh` drive table state,
`start_services.sh` runs proxy HTTP servers and a long-lived client, and
`proxy_server.py` / `long_lived_client.py` exercise real connections. That path
uses the `live_director` fallback build (`build.sh`, `PCAP_MODE`) when the DPDK
binary isn't available; the smoke test above is the authoritative, passing
verification of the real binary.

> **Watch it run:** [07-observability](./concepts/07-observability.md) +
> [`monitoring/`](./monitoring/) — a local Prometheus + Grafana stack, a live
> traffic generator, and a drain trigger to see a **failover on a dashboard**.

---

## 10. What the smoke test proves

- The **real DPDK director** boots KNI-less on a bare host (EAL, mbuf pool,
  `eth_pcap` vdev, 3-lcore busy-poll datapath).
- A bind-matching packet is **classified and encapsulated** with the exact
  documented GLB-GUE wire format (outer MAC/IP, siphash UDP sport, GUE
  protocol/hops, intact inner packet).
- A **drain** (rebuild table → `SIGUSR1` hot reload) moves the flow to the
  former secondary with the drained backend as fallback, deterministically,
  without a restart.
- The verification is **independent of the lab's wire-TX quirk** (dumper mode)
  and **cross-checks the director against the repo's own reference hashing**
  (`rendezvous_table.py`), so it would catch a real encap/routing regression.
