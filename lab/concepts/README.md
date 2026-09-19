# GLB Director — Concepts & Lab (learning index)

> A deep-dive companion to [`lab/LEARNING.md`](../LEARNING.md), written for an
> experienced **Go/Rust developer / software architect** who is new to networking.
> Each concept file maps the idea to something you already know (runtimes, channels,
> state machines, binary serialization) and links to the **actual source**. Work them
> in order — they build on each other — then set up the monitoring stack in [07].

## The reading path

| # | File | What it gives you | Prereq |
|---|------|-------------------|--------|
| 0 | [`../LEARNING.md`](../LEARNING.md) | The high-level tour: architecture, build, the passing test, gotchas | — |
| 1 | [01-networking-fundamentals](./01-networking-fundamentals.md) | Layers, IP/MAC, ports, CIDR, **the 5-tuple flow key**, endianness | — |
| 2 | [02-linux-virtual-networking](./02-linux-virtual-networking.md) | **netns / veth / bridge**, the real lab topology, DSR, FOU | 01 |
| 3 | [03-load-balancing](./03-load-balancing.md) | Stickiness, **rendezvous hashing**, primary+secondary, **draining**, anycast | 01 |
| 4 | [04-encapsulation-and-gue](./04-encapsulation-and-gue.md) | Tunneling, **GUE**, the **GLB-GUE byte layout**, the encap code path | 01, 03 |
| 5 | [05-dpdk](./05-dpdk.md) | **EAL / hugepages / PMD / lcores / mbuf / KNI / pcap vdev** | 01 |
| 6 | [06-kernel-redirect](./06-kernel-redirect.md) | netfilter/iptables, **GLBREDIRECT second chance**, the proxy decision | 03, 04 |
| 7 | [07-observability](./07-observability.md) | **metrics / packet capture / failover**, the Prometheus+Grafana stack, **how to use it** | 01–06 |

## The one-paragraph story

A client talks to one **VIP** ([03](./03-load-balancing.md)). The **director** hashes
the flow's **source IP** ([01 §4](./01-networking-fundamentals.md)) into a
precomputed **rendezvous** table row = **primary + secondary** backend ([03 §5]). It
**encapsulates** the original packet in **GUE-over-UDP**, addressed to the primary,
with the secondary riding in the GUE **private data** ([04](./04-encapsulation-and-gue.md)).
This runs at line rate in **DPDK** ([05](./05-dpdk.md)). At the proxy, **FOU**
decapsulates and the **GLBREDIRECT** kernel module either delivers locally or gives the
secondary a **second chance** ([06](./06-kernel-redirect.md)) — which is how you can
**drain** or fail over a backend **without the director holding any per-flow state**
([03 §6–7](./03-load-balancing.md)). You **watch** all of it with **metrics +
packet capture + Grafana** ([07](./07-observability.md)).

## Where the code is (map the docs to the source)

| Area | Source (repo-relative) |
|------|------------------------|
| Encap / route | [`src/glb-director/glb_encap.c`](../../src/glb-director/glb_encap.c), [`glb_encap_dpdk.c`](../../src/glb-director/glb_encap_dpdk.c) |
| GUE header struct | [`src/glb-hashing/glb_gue.h`](../../src/glb-hashing/glb_gue.h) |
| Hashing / table build | [`src/glb-director/cli/main.c`](../../src/glb-director/cli/main.c) (`build-config`; drain swap at L546–565), [`src/glb-hashing/`](../../src/glb-hashing/) |
| Control loop / statsd / reload | [`src/glb-director/glb_control_loop.c`](../../src/glb-director/glb_control_loop.c), [`statsd-client.c`](../../src/glb-director/statsd-client.c) |
| Config parsing | [`src/glb-director/glb_director_config.c`](../../src/glb-director/glb_director_config.c), [`glb_director_config.h`](../../src/glb-director/glb_director_config.h) |
| Proxy second-chance module | [`src/glb-redirect/ipt_GLBREDIRECT.c`](../../src/glb-redirect/ipt_GLBREDIRECT.c) |
| scapy GUE parser (tests/verify) | [`src/scapy-glb-gue/glb_scapy/`](../../src/scapy-glb-gue/glb_scapy/) |

## The repo's own docs (read alongside)

- [`docs/development/glb-hashing.md`](../../docs/development/glb-hashing.md) — the
  rendezvous table + proxy state machine (pairs with [03](./03-load-balancing.md)).
- [`docs/development/gue-header.md`](../../docs/development/gue-header.md) — the GUE
  header + packet-processing steps (pairs with [04](./04-encapsulation-and-gue.md)).
- [`docs/development/second-chance-design.md`](../../docs/development/second-chance-design.md) —
  the design rationale vs ECMP/LVS (pairs with [03](./03-load-balancing.md), [06](./06-kernel-redirect.md)).
- [`docs/setup/`](../../docs/setup/) — production deployment (config, forwarding
  table, healthcheck, known-good DPDK).

## The lab (runnable)

- [`lab/smoke_dpdk_director.sh`](../smoke_dpdk_director.sh) — the **passing**
  end-to-end test: encap + drain against the real DPDK director (byte-for-byte).
- [`lab/setup_topology.sh`](../setup_topology.sh) / [`start_services.sh`](../start_services.sh) —
  the full 4-netns topology with FOU + GLBREDIRECT proxies.
- [`lab/monitoring/`](../monitoring/) — the **Prometheus + Grafana** stack, a traffic
  generator, and a drain trigger to watch failover. See
  [07-observability](./07-observability.md) for how to use it.
