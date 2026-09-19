# 03 — Load balancing: stickiness, rendezvous hashing, and draining

> This is the *why* of `glb-director`. [01](./01-networking-fundamentals.md) gave you
> the flow key (the 5-tuple) and the fact that a TCP connection's state lives on one
> backend. This file is about the **problem** (keep a flow on one backend while you
> scale backends) and **GLB's answer** (a stateless precomputed rendezvous table with
> a primary + "second chance" secondary). Read the repo's own
> [`docs/development/glb-hashing.md`](../../docs/development/glb-hashing.md) and
> [`docs/development/second-chance-design.md`](../../docs/development/second-chance-design.md)
> alongside — this doc adds the conceptual framing.

## 1. What a load balancer actually is

A **load balancer (LB)** sits in front of a pool of servers (backends) and presents
**one virtual IP (VIP)** to clients. Clients connect to the VIP; the LB decides which
real backend serves each connection and steers the packets there. "Load balancing"
just means *spreading connections across the pool so no single backend is
overloaded*, while keeping each individual connection on a stable backend.

Two properties you always want:
1. **Distribution** — traffic is spread evenly across healthy backends.
2. **Stability (stickiness)** — a given connection stays on the same backend for its
   whole life, *even as the pool changes*.

Property 2 is the hard one, and it's the whole reason this project exists.

> **Analogy:** the VIP is like a `round_robin.loadbalancer:80` in front of
> `backend[0..N]:80`. But unlike a trivial proxy, the LB here must survive
> `backends` gaining/losing members *without resetting the in-flight
> `HashMap` of connections*.

## 2. L4 vs L7 load balancing

- **L4 LB** decides based on the **transport 5-tuple** (IPs + ports + protocol). It's
  fast, can be stateless, and *cannot* see the application (doesn't know it's HTTP,
  what the path is, etc.).
- **L7 LB** parses the application (HTTP path, Host header, gRPC method, etc.) and
  can route by *content* (`/images/*` → image servers). Slower, needs protocol
  knowledge, usually stateful.

**`glb-director` is an L4 LB.** It hashes the **source IP** (a chosen subset of the
5-tuple — configurable via the "hash fields") to pick a backend. It never inspects
HTTP. That's a deliberate trade: L4 is simpler, faster (line-rate, DPDK), and
stateless.

## 3. The stickiness problem, precisely

Recall from [01 §5](./01-networking-fundamentals.md): a TCP connection's state
(sequence numbers, window, the "this 5-tuple is ESTABLISHED" fact) lives **only on
the backend that handled the SYN**. If a later packet for that connection arrives at
a *different* backend, that backend's kernel says "I have no such connection" and
drops it (or, if it's a SYN, treats it as a new connection and breaks the old one).

So the LB must guarantee: **same 5-tuple → same backend, for the connection's life.**
Now make it dynamic:

- **Add a backend:** a naive "rebalance everything" rehash must move *some* existing
  connections to the new backend to stay even — and that **breaks** those
  connections (their state is on the old backend).
- **Remove a backend (drain):** its in-flight connections must be relocated without
  breaking them.

This is the core tension: **you can't move a connection's state, so you must either
( a ) never move connections (but then the pool can't rebalance), or ( b ) keep the
state somewhere the director controls.** Naive LBs pick (a) and accept broken
connections on scale events. **GLB picks a third path: reuse the state that already
exists on the backends, and give a "second chance" hop.** That's next.

## 4. Scheduling algorithms (the spectrum you'd design from)

| Algorithm | Stateless? | Cost per lookup | Rehash on pool change | Notes |
|-----------|-----------|-----------------|------------------------|-------|
| Round-robin | No (counter) | O(1) | Breaks nothing *but* can't survive scale | Needs shared counter across LBs |
| Random | Yes | O(1) | Uneven under scale | Fine for stateless apps |
| Consistent hashing (ring) | Yes | O(log N) | ~1/N keys move | Classic; still needs a "what if that node's down" story |
| **Rendezvous / HRW** | **Yes** | **O(N)** | **~1/N keys, minimal** | Each candidate scores independently; pick the max |

**Rendezvous hashing** (a.k.a. *Harmonic / Highest Random Weight*) is the key idea.
For a flow key `k`, and each candidate server `s`, compute a score
`score = H(s, k)` (a hash). The server with the **highest score** wins. Properties:
- **Stateless:** no shared table/counter; any LB with the same candidate set picks
  the same server.
- **Minimal rehash:** add/remove a server and only the keys that *would* have gone
  to the changed set move (≈ 1/N), and they move to their *next-best* server.
- **Cost:** O(N) per lookup (hash every candidate). At line rate you can't afford
  O(N) per packet.

> **Go/Rust analogy:** rendezvous is `candidates.iter().max_by_key(|s| hash(s, key))`
> — stateless and trivially correct, but O(N). The classic optimization is to
> **precompute** the result into a table so the hot path is O(1).

## 5. GLB's design: precompute the O(N) answer into a 2^16 table

GLB keeps rendezvous hashing's *semantics* but pays its O(N) cost **once, offline**,
not per packet:

1. **Hash the flow** to a **row index**: `row = siphash24(hash_key, src_ip) & 0xffff`.
   (A 64-bit siphash of the source IP, truncated to 16 bits → `2^16 = 65536` rows.)
2. **Each row** stores a **precomputed (primary, secondary) pair** of backends,
   produced by running rendezvous hashing *for that row*: for each candidate backend
   `b`, score `H = siphash24(row_seed, b.ip)` where `row_seed =
   siphash24(table_seed, row_index)`; sort candidates by score; **top = primary,
   2nd = secondary**.
3. **Per packet:** `row = hash(src_ip) & 0xffff; (primary, secondary) =
   table[row];` → **O(1)**. Encapsulate to `primary`, put `secondary` in the GUE hop
   list.

The table is built by `glb-director-cli build-config` (the `cli/main.c` `build`
command — see the `qsort` + swap at
[`cli/main.c:543-565`](../../src/glb-director/cli/main.c)) and hot-loaded into the
running director via `SIGUSR1` (`systemctl reload` in production).

**Why this is clever:**
- **Stateless & O(1):** the director holds a *static* table, no per-flow state, and
  the hot path is one hash + one array read. Line-rate friendly (DPDK).
- **Rendezvous correctness for free:** because each row is a rendezvous ranking,
  adding/removing a backend re-ranks only the rows where that backend was in the top
  two — i.e. minimal, predictable rehash.
- **The table size is the tunable:** `2^16` rows gives a fine-grained, ~uniform
  distribution of *which secondary backs which primary* (see §7).

> **Architect's framing:** this is *"precompute the expensive pure function into a
> lookup table."* Rendezvous is a pure function `f(row, backend_set) → (primary,
> secondary)`. GLB evaluates it for all `2^16` rows and caches the result. When the
> backend set changes, it re-evaluates and atomically swaps the table. The DPDK
> datapath never calls the O(N) function — it just reads the table.

## 6. Why *primary + secondary* (the "second chance")

A single backend per row can't do graceful drain/failover (there's nowhere to send an
orphaned connection). GLB stores **two** per row:

- **Primary** = where *new* connections (SYNs) go, and where an in-flight connection
  is *expected* to be.
- **Secondary** = the **fallback**. If a packet arrives at the primary but the
  primary's kernel says "not a local connection and not a SYN" (i.e. it's a packet
  for a connection whose state is actually on the *other* server), the primary
  **forwards it to the secondary** (the "second chance").

This is the linchpin: **the director never stores which backend a flow is on.** It
just always ships the primary + a one-deep fallback in the packet. The *decision* of
"do I understand this packet?" is made by the **backend using its own kernel TCP
state** — the single source of truth. See
[`docs/development/second-chance-design.md`](../../docs/development/second-chance-design.md)
for the comparison to ECMP/LVS.

> **Analogy:** it's like a `HashMap` where you don't store the bucket assignment.
> Instead every request carries *both* the expected bucket **and** the backup bucket.
> The target checks its own table; if the key isn't there, it retries the backup.
> No coordinator, no shared state, and a removed bucket is handled by the backup.

## 7. The backend state machine (and the drain swap)

Each backend has a **state** (JSON → enum in [`cli/main.c:55-57`](../../src/glb-director/cli/main.c)):

| JSON state | enum value | Included in table? | Meaning |
|------------|-----------|--------------------|---------|
| `filling`  | 0 (FILLING) | yes | just joined; behaves like active |
| `active`   | 1 (ACTIVE) | yes | normal |
| `draining` | 2 (DRAINING_INACTIVE) | yes | leaving; still reachable as fallback |
| `inactive` | (excluded) | **no** | removed from the pool |

The lifecycle is `filling → active → draining → inactive (removed)`. The design
requires **at most one backend** in a non-`active` state at a time (a deliberate
operational constraint that has worked well in production).

**The drain swap** (the heart of graceful drain, [`cli/main.c:546-565`](../../src/glb-director/cli/main.c)):
when a row's **primary** would be `draining` (or unhealthy) *and* the **secondary** is
`active`, the table builder **swaps** them for that row:

```
before drain:   row -> primary=A(active), secondary=B(active)
A starts drain: row -> primary=B(active), secondary=A(draining)   # swapped
```

Effect:
- **New connections** to that row now go to **B** (the new primary) — A gets no
  fresh SYNs.
- **In-flight connections** still on A: their packets arrive at B (the new
  primary), B's kernel doesn't recognize them, so B **forwards them to A** via the
  GUE hop list (the "second chance"). A keeps serving them until they close.
- Once A's connections drain, A is set to `inactive` and **removed from the table
  entirely**; other backends shuffle in to fill the secondary slots.

So a drain is a **table rebuild + hot reload**, and the *only* per-row change is a
primary/secondary swap. That's why the smoke test's Phase 2 is: mark the flow's
primary `draining`, rebuild the table, `SIGUSR1`, and assert the flow now encaps to
the **former secondary** with the drained backend as the GUE fallback.

## 8. Why the table size / even secondary spread matters

For drain to be *gentle*, when a primary A drains, A's traffic should spread across
*many* secondaries — not all pile onto one. GLB achieves this by making the table
large (`2^16`) so that for each primary, its secondary is ~uniformly distributed over
the other backends. (The repo notes that once the pool grows past ~`2^8` backends you
start to see bias; the table can be enlarged trivially if needed.)

> **Analogy:** it's the difference between a `HashMap` with 16 buckets (collisions
> cluster) and one with 65536 (even spread). More rows = smoother load on drain.

## 9. Health checks & failover (no manual intervention)

The [`glb-healthcheck`](../../docs/setup/glb-healthcheck-configuration.md) component
continuously probes the tunnel/HTTP health of each backend. When it detects that a
backend that would be **primary** in some rows is **unhealthy**, it regenerates the
forwarding table with that backend demoted to **secondary** in those rows (the same
swap as a drain). This is a **temporary, best-effort, per-director** failover:

- Each director decides independently (no cross-director state sync).
- Because the secondary is *always* present in the table (even when everyone is
  `active`), a failed primary's traffic instantly has somewhere to go — the "second
  chance" hop carries it.
- It won't break connections even if directors briefly disagree on health, because
  the fallback is in-band with the packet.

So **drain** (planned) and **failover** (unplanned) are the *same mechanism*: a table
rebuild that swaps a bad primary to secondary.

## 10. Anycast: many directors, one VIP, zero shared state

Because the forwarding table is a **pure function of (hash_key, seed, backend set)**
and the director holds **no per-flow state**, you can run **many directors** behind
the same VIP (anycast). Every director computes the *identical* table, so no matter
which director a client's packet lands on, it's encaps to the *same* primary/secondary.
Directors are therefore **interchangeable and disposable** — scale them out freely,
take them down, they carry nothing that can't be recomputed. This is a big operational
win and the direct payoff of the stateless design.

## 11. Why not just ECMP or LVS? (the alternatives, briefly)

- **ECMP / plain consistent hashing (no per-flow state):** on a pool change, a
  fraction of *existing* connections must rehash to stay balanced → those connections
  break (the new backend has no state for them). Unacceptable for long-lived
  connections (e.g. `git clone/push`).
- **LVS (director holds flow state + multicast state sync):** solves it, but the
  director tier must store per-flow state *and* replicate it across directors (UDP
  multicast sync) — extra state, extra cross-communication, sync latency. GLB avoids
  all of it by **reusing the backends' existing TCP state** and a one-deep in-band
  fallback.

The trade GLB makes: **a fixed 2-server row (primary + 1 secondary)** instead of
arbitrary fan-out. That's enough for drain/failover of *one* server at a time (the
operational constraint), and it keeps the director stateless and the header small.
(The header format already supports multiple hops, so relaxing the 2-server limit is
a known future direction.)

## 12. When you'd pick this design (use cases)

- **Very long-lived connections** where a dropped connection is expensive to retry
  (GitHub's `git` protocol is the canonical example).
- **Stateless, horizontally-scaled director tier** you can scale/restart freely.
- **L4-only** requirements (no per-content routing needed).
- A pool where **≤ 1 backend** is expected to drain/fail at a time.

If you needed L7 routing, per-flow arbitrary fan-out, or to drain many backends at
once, you'd reach for a different design (LVS, or an L7 proxy like Envoy).

## 13. Key takeaways

1. A LB = **one VIP → many backends**, with two goals: **distribution** and
   **stickiness**. Stickiness under scale-change is the hard problem.
2. **GLB is L4**: it hashes the **source IP** (configurable hash fields), not content.
3. **Rendezvous/HRW** hashing is stateless + minimal-rehash but **O(N)** per lookup;
   GLB **precomputes** it into a `2^16` table (row = `siphash(src_ip) & 0xffff`) so
   the datapath is **O(1)**.
4. Each row = **primary + secondary**. The secondary is the **second chance**: a
   packet the primary doesn't recognize is forwarded to the secondary. This is how
   the director stays **stateless** while connections survive.
5. **Drain = failover = a table rebuild that swaps a bad primary to secondary.**
   States: `filling/active` (in table) → `draining` (in table, swapped when primary)
   → `inactive` (removed).
6. **Anycast** falls out of statelessness: all directors compute the same table, so
   directors are interchangeable and disposable.
7. The design trades a **fixed 2-server row** for **zero director state + in-band
   fallback** — ideal for long-lived, hard-to-retry connections.
