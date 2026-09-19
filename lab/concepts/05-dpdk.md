# 05 — DPDK: the userspace datapath engine

> The director's job is "hash a 5-tuple, look up a table, prepend headers, send" —
> millions of times per second. The **Linux kernel network stack can't do that at
> line rate**, because of per-packet overhead. **DPDK** (Data Plane Development Kit)
> is the toolkit that moves that hot loop into userspace. This file explains the
> concepts so the director's launch command and config make sense. If you've built
> runtimes or high-throughput servers, most of this maps directly.

## 1. The problem: the kernel is slow *per packet*

The kernel network stack (the one that handles your `eth0`) is optimized for
*generality*, not raw per-packet throughput. Every packet that traverses it costs:
- **A context switch / interrupt** (the NIC raises an interrupt; the CPU saves
  context, runs the interrupt handler, switches to kernel mode).
- **Syscall boundaries** (userspace ↔ kernel memory copies, e.g. `recvfrom`).
- **Per-packet bookkeeping** (sk_buff allocation, NAPI polling, qdisc, conntrack,
  netfilter hooks, socket lookup).

Any *one* of these is a few hundred nanoseconds to microseconds. At 10M+ packets/
sec, that adds up to more CPU than the machine has. The actual *useful* work
(hash + table lookup + header edit) is maybe tens of nanoseconds; the rest is
*framework tax*.

> **Analogy:** it's the difference between a framework that does reflection,
> dependency injection, logging, and validation *per request* vs. a tight hand-written
> loop. The useful work is the same; the framework tax is the difference. DPDK
> removes the framework tax from the packet hot path.

## 2. The three DPDK pillars

### 2a. Polling instead of interrupts (the big one)

- **Interrupt-driven (kernel):** NIC has a packet → raise interrupt → CPU wakes,
  context-switches, handles it. Good for low/variable load (CPU sleeps otherwise).
  Bad for sustained high load (interrupt storms, context-switch overhead).
- **Poll-mode (DPDK):** a dedicated core **spins in a tight loop** calling
  `rte_eth_rx_burst()`, draining as many packets as are ready, *with no interrupt and
  no context switch*. Zero-wait, but that core is **busy 100%** of the time.

> **Analogy:** interrupt-driven is a `tokio` task that `await`s a `waker` (the
> thread sleeps until woken). Poll-mode is a **dedicated thread that busy-waits**
> (`while let Some(pkt) = queue.try_pop() { ... }`) — never sleeps, never context
> switches, pays a full core's CPU to do it. You *trade CPU for latency/throughput*.
> This is a deliberate, well-understood trade in high-perf systems (e.g. spinning
> locks, busy-poll sockets).

### 2b. Pre-allocated packet buffers (mbufs) — no per-packet allocation

A **`rte_mbuf`** is DPDK's packet buffer: a small **header struct** (data pointer,
lengths, refcount, metadata, a pointer into a data area) that front-ends a **byte
buffer** holding the actual packet. Key properties:
- **Fixed-size, pre-allocated in a pool** (a lock-free **ring** of N mbufs). There is
  **no `malloc`/`free` in the hot path** — you take an mbuf from the pool, use it,
  return it. (Like a custom `Arena`/object pool, or a `Vec` you reuse.)
- **Headroom**: each mbuf reserves free space *before* the packet start, so you can
  **prepend headers** (encapsulation!) by moving the data pointer back — no payload
  copy. That's exactly what [04 §7](./04-encapsulation-and-gue.md) does.
- **Refcount**: an mbuf can be shared (e.g. between queues) without copying; freeing
  only happens when the last reference drops.

> **Architect's note:** the mbuf pool is a **bounded resource**. If the pool is
> exhausted (you hold more mbufs than exist), RX **drops** packets and the
> `rx_nombuf` counter rises. This is why the pool *size* and the DPDK memory
> reservation (`--socket-mem`) matter — see §6 and [07](./07-observability.md).

### 2c. Hugepages — large memory pages to cut TLB misses

DPDK reserves a big contiguous memory region at startup from **hugepages**
(typically **2 MiB** pages instead of 4 KiB). Why:
- Fewer, larger pages → fewer **TLB** entries → fewer **TLB misses** when the
  datapath touches packet memory at high speed.
- A large contiguous region simplifies the memory model (one arena everything lives
  in) and pins it in RAM (no paging/swapping of hot buffers).

You enable hugepages in the kernel (`vm.nr_hugepages`, the `hugetlbfs` mount at
`/dev/hugepages`). DPDK's EAL maps them and records the mapping in
`/dev/hugepages/rtemap_*` files. **These files pin the memory** — if a DPDK process
dies uncleanly, stale `rtemap_*` files can leave the pool reserved (the smoke test
`rm -f /dev/hugepages/rtemap_*` in pre-flight and cleanup for exactly this).

> **Analogy:** hugepages are like reserving one big `Arena` up front instead of
> doing thousands of tiny `malloc`s; the CPU's address-translation cache (TLB) has
> far fewer entries to manage.

## 3. EAL: the runtime bootstrap

The **EAL (Environment Abstraction Layer)** is DPDK's runtime init — the thing you
call once at process start that:
- reserves the hugepage memory arena,
- initializes the NIC **PMDs** (drivers),
- sets up the **lcore** execution model,
- provides the memory/atomic/ring primitives the rest of DPDK uses.

> **Analogy:** EAL is `std::rt::init()` / `tokio::runtime::Builder::build()` — the
> one-time setup that reserves resources and stands up the execution model before
> your main loop runs. In the director's launch, everything *before* the `--`
> (`-c 0x7 --socket-mem=... --vdev=...`) is **EAL args**; everything *after* the `--`
> (`--config-file ... --forwarding-table ...`) is **the director's own args**.

## 4. PMD: the poll-mode driver

A **PMD (Poll Mode Driver)** is DPDK's NIC driver — the code that talks to a specific
NIC (or a *virtual* device) in poll mode. You pick/enable PMDs; the EAL loads them.
Examples: `net_i40e`/`net_ixgbe` (real Intel NICs), `net_af_packet`, and — crucially
for the lab — **`eth_pcap`** (a *virtual* PMD, see §9).

> **Analogy:** a PMD is a concrete impl of a `Driver` trait (poll `rx()`, `tx()`).
> The EAL is the runtime that instantiates the right one for your hardware/vdev.

## 5. lcores: the CPU cores DPDK owns

**lcores** are the CPU cores (a bitmask) you hand to DPDK. Each runs a **lcore
function** — a tight loop that never returns. The director's config assigns roles:

```jsonc
"lcores": {
  "lcore-1": { "rx": true, "tx": true, "flow_paths": [0], "dist": true, "num_dist_workers": 1 },
  "lcore-2": { "work": true, "work_source": 1 }
}
```

- The **master lcore** runs the **control loop** (`main_loop_control`): config
  handling, statsd emission, and the **SIGUSR1 reload** path.
- The **RX/DIST lcore** (`rx:true, dist:true`) **polls the RX queue**, classifies
  each packet, and *distributes* (enqueues) it to worker lcores.
- The **worker lcore** (`work:true`) **encapsulates** (the [04 §7](./04-encapsulation-and-gue.md)
  code) and **TXes** the result.

This is a **producer/consumer pipeline** (RX→distribute→worker→TX) across cores,
connected by **lock-free rings** (mbuf queues). Each stage is a dedicated spinning
lcore.

> **Analogy:** it's a multi-stage pipeline of actors, each pinned to a core and
> communicating over lock-free queues (`RcRef`-shared mbufs + `Ring`), no locks, no
> syscalls. The control lcore is the "supervisor" actor that handles out-of-band
> messages (reload, stop) and metrics.

## 6. Memory: ports, queues, flow_paths, and `--socket-mem`

- A **port** = a (virtual) NIC. A port has **RX queues** and **TX queues** (hardware
  queuing; each queue can be polled by a different lcore for parallelism).
- A **flow_path** binds an `(rx_port, rx_queue)` to a `(tx_port, tx_queue)` — i.e.
  "packets that arrive here leave there." The config's `flow_paths` list defines
  these, and lcores reference them by index.
- **`--socket-mem=832,0`**: reserves how much hugepage memory per NUMA socket
  (832 MiB on socket 0, 0 on socket 1). This is the **arena size**. It must be big
  enough for the mbuf pool(s) + other DPDK memory. The lab's bionic DPDK 17.11 is
  built with `CONFIG_RTE_MAX_MEMSEG=256`, capping the default reservation; the
  mbuf pool alone is ~625 MiB, hence the explicit `832`. If it's too small, EAL
  **fails to reserve memory at startup** (a common "it won't launch" cause).

> **Architect's note:** `--socket-mem` is the *arena size*. Too small → init fails;
> too big → you pin more of the host's RAM than you need. It's a deployment knob,
> not a correctness knob (within reason).

## 7. KNI: the escape hatch back to the kernel

**KNI (Kernel NIC Interface)** is a virtual interface that lets a DPDK app **hand a
packet to the kernel** (and vice-versa). Use it for traffic DPDK shouldn't/doesn't
handle — e.g. **ICMP ping responses** (the config has `forward_icmp_ping_responses`),
or any flow that must go through normal kernel processing. The director counts
`core.packets.kni` for packets sent to KNI.

> **Analogy:** KNI is a `Unix socket`/`pipe` between your userspace datapath and the
> kernel stack — a controlled boundary for the "we can't handle this fast path"
> traffic. (The lab host has no working `rte_kni` on its kernel, so the smoke test
> runs with KNI off.)

## 8. The `eth_pcap` PMD: a virtual NIC that reads/writes pcap files

The **`eth_pcap`** vdev is a *virtual* PMD that doesn't touch a real wire — it
**RXes from and/or TXes to a pcap file / a kernel interface**. This is the lab's
workhorse and the reason the smoke test works despite the wire-TX quirk (§9 of
[LEARNING.md](../LEARNING.md)):

```
--vdev=eth_pcap0,rx_iface=glbt_dpdk,tx_pcap=/tmp/glb-smoke/tx_dump.pcap
```
- `rx_iface=glbt_dpdk`: RX from the real veth `glbt_dpdk` (where scapy sends the
  crafted client packet).
- `tx_pcap=<file>`: **TX to a pcap file** instead of a wire. The director's
  encapsulated output is written to the file **byte-for-byte**, and we parse it with
  scapy to verify. This captures *exactly* what the director produced, independent of
  any wire-delivery quirk.

> **Analogy:** it's a test double / faked `Driver` impl: same interface, but instead
> of sending to hardware it records to a log (the pcap) you can assert against.

## 9. Why the lab uses bionic DPDK 17.11 (not the distro's)

The lab host is **Debian 12 (bookworm)**, whose packaged DPDK is **22.11** — but that
build is **meson-only**, and `glb-director`'s Makefile uses the classic **DPDK
make** build system. So the lab stages a **bionic (Ubuntu 18.04) DPDK 17.11** SDK
(under `~/dev/glb-build/dpdk17`) that still has the make build + the PMDs the
director expects, and builds/runs against it with `RTE_SDK`/`RTE_TARGET` and a
matching `LD_LIBRARY_PATH` at runtime. This is a *lab convenience*, not a glb-director
requirement — production uses a compatible DPDK per
[`docs/setup/known-compatible-dpdk.md`](../../docs/setup/known-compatible-dpdk.md).

## 10. Reading the director's launch (putting it together)

```bash
glb-director \
  -c 0x7 \                    # EAL: use cores 0,1,2  (bitmask)
  --socket-mem=832,0 \        # EAL: 832MiB arena on socket 0
  --vdev=eth_pcap0,rx_iface=glbt_dpdk,tx_pcap=/tmp/glb-smoke/tx_dump.pcap \
  -- \                        # --- end of EAL args, start of director args ---
  --debug \
  --config-file /tmp/glb-smoke/config.json \   # lcores, flow_paths, MACs, statsd
  --forwarding-table /tmp/glb-smoke/fwd.bin    # the precomputed table (SIGUSR1 reloads)
```

- `-c 0x7` → 3 lcores (master + rx_dist + worker, per the config).
- `--vdev` → the `eth_pcap` dumper (RX real veth, TX to pcap).
- `--config-file` → the JSON (lcores/flow_paths/`outbound_gateway_mac`/
  `outbound_src_ip`/`statsd_port`).
- `--forwarding-table` → the binary table built by `glb-director-cli build-config`;
  **`SIGUSR1`** re-reads this path and hot-swaps it (the drain/reload path —
  [03 §7](./03-load-balancing.md), [07 §6](./07-observability.md)).

## 11. Key takeaways

1. The **kernel is too slow per packet** (interrupts + syscalls + bookkeeping). DPDK
   removes that tax from the hot path.
2. **Poll mode** = a dedicated core spins on `rx_burst()` (no interrupt/context
   switch); trades a full core's CPU for max throughput/low latency.
3. **mbufs** = pre-allocated, pooled, refcounted packet buffers with **headroom**
   (encap = move the data pointer back, no copy). The pool is **bounded** → `rx_nombuf`
   drops when exhausted.
4. **Hugepages** = a big pre-reserved arena (2 MiB pages) to cut TLB misses; stale
   `rtemap_*` files can pin it after a crash.
5. **EAL** = the one-time runtime init (before `--`); **PMD** = the NIC driver;
   **lcores** = the spinning cores, each a pipeline stage (RX→dist→worker→TX) over
   lock-free rings; the **master lcore** = control (config/stats/reload).
6. **KNI** = the controlled path back to the kernel (e.g. ICMP). **`eth_pcap`** = a
   virtual PMD that reads/writes pcap files (the lab's capture mechanism).
7. **`--socket-mem`** = the arena size (a deployment knob); the lab uses bionic
   DPDK 17.11 because the distro's is meson-only and the Makefile is make-based.
