# 06 — The proxy side: netfilter, FOU, and the GLBREDIRECT "second chance"

> [03](./03-load-balancing.md) said the director is *stateless* and reuses the
> **backends' existing TCP state** for the "second chance." [04](./04-encapsulation-and-gue.md)
> showed the **hop list** riding in the GUE private data. This file is *how a proxy
> actually makes that decision and forwards a packet it doesn't own* — a custom
> **iptables target** (`GLBREDIRECT`) that runs in the kernel, in the fast path,
> reading the kernel's own TCP connection table. Read the repo's
> [`docs/development/second-chance-design.md`](../../docs/development/second-chance-design.md)
> and the module [`src/glb-redirect/ipt_GLBREDIRECT.c`](../../src/glb-redirect/ipt_GLBREDIRECT.c).

## 1. The problem at the proxy

Recall the flow after the director encaps
([04 §8](./04-encapsulation-and-gue.md)):
1. The **primary** proxy receives the GUE packet.
2. **FOU** (the kernel module registered for UDP port `19523`) decapsulates it: strips
   outer IP+UDP+GUE and injects the **inner** IP packet into the local stack.
3. The local stack now sees "an IP packet for the VIP, from the client."

Now the crux: **is this packet for a connection that lives on *this* proxy?**
- If it's a **SYN** (new connection) → yes, handle it here (create the connection).
- If it matches an **ESTABLISHED** local connection → yes, handle it here.
- If it's **neither** (a data packet for a connection whose state is actually on the
  *other* proxy) → the local kernel would just **drop it** (or RST it). But we *want*
  to give the **other** proxy a chance — that's the second chance.

The decision "do I own this flow?" can only be answered by **this proxy's kernel TCP
state** — which is exactly the state the director deliberately *doesn't* store.

## 2. Netfilter / iptables in 60 seconds (the hooks model)

Linux processes every packet through the **netfilter** framework: a set of fixed
**hook points** along the packet path where rules/modules can inspect and act. For
IPv4 the hooks are:

```
                 +-------------+
   RX --->        | PREROUTING  |  (before local routing decision)
                 +------+------+
                        |
                 +------+------+
        (if dst is |              |
         local)    |   INPUT      | ---> local delivery (socket)
                 +------+------+
                        |
        (if forwarding) |   FORWARD  | ---> to another interface
                 +------+------+
                        |
                 +------+------+
   TX <---        | POSTROUTING |  (before leaving the host)
                 +-------------+
```

- **iptables** (and **nftables**) install **rules** at these hooks. A rule *matches*
  on packet fields (protocol, port, etc.) and takes an **action**: `ACCEPT`, `DROP`,
  or **jump to a target/module** (`-j <TARGET>`).
- A **custom target** can be a **kernel module** that does arbitrary in-kernel logic
  — that's what `GLBREDIRECT` is.
- The **`raw`** table runs *before* conntrack (connection tracking) and is used to
  mark packets as `--notrack` (skip conntrack).

> **Analogy:** netfilter is a **middleware chain** (like Express/Koa/actix
> middleware) that every packet passes through. Each hook is a middleware point; each
> rule is a handler that can short-circuit (`DROP`/`ACCEPT`) or delegate (`-j`).
> `GLBREDIRECT` is a custom middleware handler written in C, compiled into the kernel.

## 3. How FOU and GLBREDIRECT coexist (the two iptables rules)

In the lab, each proxy has ([`setup_topology.sh:103-104`](../../lab/setup_topology.sh)):
```bash
iptables -t raw   -A INPUT -p udp --dport 19523 -j CT --notrack   # (a)
iptables      -A INPUT -p udp --dport 19523 -j GLBREDIRECT         # (b)
```
- **(a) `raw` + `CT --notrack`:** mark GUE (UDP/19523) packets so **conntrack ignores
  them**. Without this, the kernel's connection tracker would treat the *tunnel* as a
  connection and get confused (the tunnel's 5-tuple ≠ the inner flow's). Running it in
  `raw` (before conntrack) is required for `--notrack` to take effect.
- **(b) `GLBREDIRECT` target in `INPUT`:** runs on the *still-encapsulated* packet
  (outer UDP + GUE + inner) **before** the inner packet is delivered. It decides:
  **deliver locally** (return `XT_CONTINUE` → FOU decaps + local delivery) or
  **steal & forward to the next hop** (rewrite + re-inject, return `NF_STOLEN`).

So the *order* is: GUE arrives → (a) skip conntrack → (b) GLBREDIRECT inspects the
GUE hop list + inner 5-tuple → either continue (FOU decaps, local) or forward. FOU
only decaps when GLBREDIRECT says "this one's for me."

## 4. The decision logic (the second chance, precisely)

[`glbredirect_handle_inner_tcp_generic()`](../../src/glb-redirect/ipt_GLBREDIRECT.c),
for an inner **TCP** packet, in order:

1. **SYN?** → **accept locally** (`accepted_syn_packets`). New connections are always
   taken by the server they arrive at. (A SYN has no "previous owner.")
2. **`is_valid_locally()`?** → **accept locally** (`accepted_established_packets` /
   `accepted_syn_cookie_packets`). This checks the kernel's **established-connection
   hash** (`inet_lookup_established`) for the inner 5-tuple — "do I have a socket for
   this exact flow?" It also accepts a valid **SYN-cookie ACK** (for connections
   completed under SYN-cookie load). **This is the "reuse the backend's existing TCP
   state"** — the single source of truth.
3. **Not valid locally** (a packet for a connection owned elsewhere):
   - **No more hops** (`next_hop >= hop_count`) → **accept locally as a last resort**
     (`accepted_last_resort_packets`). We've exhausted the fallbacks; the local stack
     is the best option (it can at least handle the response). The module notes this
     is a *symptom of a mis-constructed forwarding table* — in a correct table this
     shouldn't happen.
   - **Next hop == me** (`hops[next_hop] == outer dst`) → **accept locally**
     (`forwarded_to_self_packets`), defensively, to avoid a forwarding loop.
   - **Otherwise** → **forward to `hops[next_hop]`** (`forwarded_to_alternate_packets`):
     the actual second-chance hop (§5).

> **Analogy:** it's a `match (pkt) { SYN => local, ESTABLISHED(if mine) => local,
> _ if hops_remain => forward(next), _ => local /* last resort */ }`. The whole
> "is this mine?" check is a single read of the kernel's `HashMap` of sockets —
> no director involved.

### A subtle, documented edge case
If an app `close()`s a socket that still has data in its receive buffer, the kernel
sends a RST and **immediately unhashes** the socket — so a subsequent packet for that
flow can no longer be found locally and will be "accepted" at the *last* hop, which
RSTs it. The RST is **byte-identical** to what the original host would send (it's
deterministic from the incoming packet), so the **client sees consistent behavior**
even though a different machine generated the RST. (Documented in the module with
kernel source links.)

## 5. The forward: rewrite the *outer* GUE and re-inject

When forwarding to the alternate (`glbredirect_send_forwarded_skb` + the generic
handler), the module operates on the **outer** packet (the inner is untouched):

```c
raw_cr->next_hop++;                 // advance the hop index in GUE private data
outer_ip->saddr = outer_ip->daddr;  // my IP (old dst) becomes the new src
outer_ip->daddr = alt;              // the next hop becomes the new dst
// incrementally fix the UDP checksum for the changed bytes, then:
ip_route_me_harder(...);            // re-route the rewritten packet
ip_local_out(...);                  // inject into the kernel output/forward path
```

Key insight: **the GUE envelope (with its hop list) is the forwarding state, and it
travels with the packet.** Each proxy that can't handle the flow just *advances
`next_hop`* and re-addresses the outer IP to the next hop. The chain terminates when
a proxy recognizes the flow (SYN/established) or the hops are exhausted. Because the
director always ships primary + one fallback, the chain is normally at most **two**
hops long.

> **Architect's note:** this is *stateless in-band forwarding*. No proxy keeps a
> "I forwarded flow X to Y" table; the packet itself carries where to go next. It's
> like **source routing** / a "next pointer" embedded in the message. (Compare to a
> `HashMap<flow, next_hop>` that would have to be shared — GLB avoids it.)

## 6. The full drain packet flow (tying it all together)

Setup: flow F's row was `primary=A, secondary=B`. A starts **draining** → the table
is rebuilt + reloaded → the row becomes `primary=B, secondary=A` ([03 §7](./03-load-balancing.md)).
Now an **in-flight** packet of F (whose connection state is still on **A**) arrives:

```
client --F--> director --(encap: outer dst=B, GUE hops=[A])--> B
                                                        |
                                     B's GLBREDIRECT: SYN? no. established on B? no.
                                                        | next_hop=0 < hop_count=1
                                     forward to hops[0]=A: outer dst=A, next_hop=1
                                                        |
client <== response  A <--(FOW decaps, inner is B's... no, A's connection) A
                                                        |
                                     A's GLBREDIRECT: established on A? YES
                                                        |
                                                        v
                                              deliver locally (A keeps serving F)
```

- **New connections** of F now go straight to **B** (the new primary) — A gets no
  fresh SYNs.
- **In-flight** packets of F are bounced A→B→A (one second-chance hop) and **kept
  alive on A** until they close. No connection is broken.
- Once F's in-flight connections finish, A is set to `inactive` and removed.

The whole thing is driven by (a) the **table swap** at the director and (b) the
**hop list** in the GUE header — no shared state anywhere.

## 7. Why a kernel module (and not userspace)?

- **Line rate:** the proxy receives every GUE packet; the decision must be made in the
  kernel's fast path with no userspace round-trip (a `AF_PACKET` userspace hop would
  add the same per-packet cost DPDK eliminates on the director side).
- **Access to local TCP state:** the module can call `inet_lookup_established()`
  directly — the *actual* connection table. A userspace process can't see that state
  as cheaply or as authoritatively.
- **In-kernel rewrite + re-inject:** `ip_local_out()` re-injects the rewritten packet
  into the routing/forwarding path atomically.
- **Cost of a kernel module:** it must be compiled against the running kernel's
  headers (the Makefile here *probes* header arities for kernel-version drift — see
  the `GLB_COOKIE_CHECK_*` / `GLB_INET_LOOKUP_*` shims), and it's GPL (to be kernel-
  compatible). That's the standard trade for in-kernel data-path logic.

## 8. Proxy-side observability: `/proc/glb_redirect_stats`

The module keeps **per-CPU counters** (read atomically) and exposes them at
**`/proc/glb_redirect_stats`**:

```
total_packets: ...
accepted_syn_packets: ...
accepted_last_resort_packets: ...
accepted_established_packets: ...
accepted_syn_cookie_packets: ...
forwarded_to_self_packets: ...
forwarded_to_alternate_packets: ...
```

These are the **proxy-side** health/failover signals (the director's statsd metrics
are the *director-side* ones — see [07](./07-observability.md)). During a drain,
watch `forwarded_to_alternate_packets` climb on the *new* primary (it's bouncing
in-flight connections to the draining one), and `accepted_last_resort_packets` — if
that rises, the table is wrong. This is a cheap, always-on failover monitor.

## 9. Key takeaways

1. The proxy's question — "**do I own this flow?**" — is answered by **its own kernel
   TCP state** (`inet_lookup_established`), which is the state the director avoids
   storing.
2. **netfilter/iptables** = a middleware chain of hooks; **`GLBREDIRECT`** is a custom
   **kernel target** on the `INPUT` hook for UDP/19523, running **before** FOU decaps.
3. The decision: **SYN → local**; **established/SYN-cookie → local**; **no more hops →
   local (last resort)**; **next hop == me → local**; **else → forward to the next
   hop**.
4. Forwarding = **advance `next_hop`, swap outer src/dst, fix checksum, re-inject** —
   the GUE hop list is *in-band, stateless forwarding state*.
5. **`raw --notrack`** keeps conntrack from confusing the tunnel with the flow.
6. It's a **kernel module** for line-rate access to local TCP state (trade: must match
   kernel headers, GPL).
7. **`/proc/glb_redirect_stats`** gives the proxy-side failover/drain signals.
