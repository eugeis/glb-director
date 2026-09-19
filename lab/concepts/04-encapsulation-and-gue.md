# 04 — Encapsulation & GUE: putting a packet inside a packet

> You now know the director picks a **primary + secondary** per flow
> ([03](./03-load-balancing.md)) and that packets are nested envelopes
> ([01](./01-networking-fundamentals.md)). This file is *how the director physically
> sends a packet to the primary while telling the primary "and here's the backup in
> case you can't handle it."* That "and here's the backup" rides in the **GUE private
> data** area. Read the repo's
> [`docs/development/gue-header.md`](../../docs/development/gue-header.md) alongside.

## 1. Why encapsulate (the motivation)

The director must get a client's packet to a *specific backend* (the primary), but:
- The client addressed the packet to the **VIP** (e.g. `10.0.0.1`), not to the
  backend. If the director just forwarded it, the VIP would route to *some* backend
  by normal IP rules — not necessarily the hashed primary.
- The director needs to **carry a hint** (the secondary) that isn't part of the
  original packet, and that hint must travel *with the packet* to wherever it ends up
  (the "second chance" needs it at the backend, statelessly).

**Encapsulation (tunneling)** solves both: the director wraps the *entire original IP
packet* inside a **new** IP+UDP packet addressed to the primary. The inner packet is
opaque to the outer path (routers only see "send this to the primary"), and the
director can stash its hint (the hop list) in the new envelope's header.

> **Analogy:** it's sending a `letter` (the client's packet) inside an `envelope`
> (the outer IP/UDP) addressed to the primary, with a `P.S. on the envelope` (the GUE
> private data) saying "if you can't open/deliver this, hand it to <secondary>." The
> outer routing only cares about the envelope address; the P.S. is metadata for the
> recipient.

## 2. Tunneling 101: outer vs inner

A tunnel = **outer header** (used to route the tunnel to its endpoint) + **inner
payload** (the original packet, treated as opaque bytes). On the wire:

```
[ Outer Eth | Outer IP (src=director, dst=primary) | Outer UDP | Tunnel hdr | Inner IP | Inner L4 | payload ]
```

Common tunnel families:
- **IPIP** (IP-in-IP, proto 4): wrap an IP packet in another IP packet. Minimal, but
  no port → hard to ECMP/RSS-steer, and some middleboxes dislike raw IP tunnels.
- **GRE** (Generic Routing Encapsulation, proto 47): IP-in-IP + a flexible header
  (key, sequence, checksum). Versatile but no UDP port either.
- **FOU / GUE** (Foo-over-UDP / Generic UDP Encapsulation): wrap in **UDP**. This is
  the family GLB uses.

## 3. Why *UDP* for the tunnel

Using a UDP outer header (vs raw IPIP/GRE) buys practical wins:
- **A UDP destination port** (`19523`) identifies the tunnel → trivial to match with
  `iptables`/`fou`/DPDK rules, and to `tcpdump`/filter on.
- **A UDP source port the director controls** → used to **spread flows across ECMP
  paths and NIC RX queues** (see §6). This is the big one for a datacenter LB.
- **Firewall/NAT/MTU friendlier** than raw IP tunnels in many networks.

The cost: a few extra bytes and a UDP checksum (left `0`/optional here).

## 4. GUE (Generic UDP Encapsulation) — the IETF header

GUE (an IETF draft) is a small, extensible header that sits between the outer UDP and
the inner IP. Its **base header** is 4 bytes:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Ver  |C|    Hlen   |  Protocol |            Flags            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      ... variable options ...                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```
- **Ver** = GUE version (0). **C** = "critical options present" (0). **Hlen** = header
  length in 4-byte units.
- **Protocol** = the *type of the encapsulated (inner) packet* — an IANA protocol
  number. For GLB this is **the inner IP version**: `4` (IPv4) or `41` (IPv6).
  (⚠️ This is *not* the L4 protocol — a classic gotcha. It's "what kind of IP is
  inside," not "TCP or UDP inside.")
- **Flags** = reserved (0).
- **Options / private data** = a variable-length area. GUE is *extensible by design*;
  vendors can define their own option types. **GLB uses this area** to carry its hop
  list. The Linux kernel's FOU module, which decapsulates GUE, **ignores the private
  data** (it only needs the inner IP) — which is why the GLB-specific extension can
  ride along without breaking standard GUE handling.

## 5. The GLB-GUE wire format (exact)

GLB's GUE header, as laid out by
[`src/glb-hashing/glb_gue.h`](../../src/glb-hashing/glb_gue.h)
(`struct glb_gue_hdr`, `__packed__`):

```
offset  size  field                  value / meaning
------  ----  ---------------------  ---------------------------------------------
  0      1    version_control_hlen   Ver=0, C=0, Hlen=(1 + hop_count)  [4-byte words]
  1      1    protocol               inner IP version: 4 (IPv4) / 41 (IPv6)
  2      2    flags                  0
  4      2    private_type           0  (reserved; room for future GLB versions)
  6      1    next_hop               0  (index of the hop to try next; starts at 0)
  7      1    hop_count              number of IPv4 addresses in hops[]
  8     4*n   hops[n]                n IPv4 addresses, network byte order
```

where `n = hop_count`. For the common 2-backend case, the director computes two hops
(primary, secondary); the **first** hop becomes the **outer IP dst** (so it's *not*
repeated in `hops[]`), and `hops[]` holds the **remaining** hops (just the secondary).
So for 2 backends: `hop_count = 1`, `hops[0] = secondary`.

**Worked example** (the smoke-test flow, backends `.20`/`.21`, primary=`.21`):

```
Outer Eth:  dst = br0 MAC (outbound_gateway_mac),  src = director NIC MAC
Outer IP:   src = 65.65.65.65 (outbound_src_ip),  dst = 192.168.100.21 (primary)
             proto = 17 (UDP)
Outer UDP:  src = 61139 (the hash),               dst = 19523
GUE:        ver/c = 0, hlen = 2, protocol = 4, flags = 0
            private_type = 0, next_hop = 0, hop_count = 1
            hops[0] = 192.168.100.20 (secondary)
Inner:      the original client packet, byte-for-byte unchanged
             IP src=10.11.12.13 dst=10.0.0.1, TCP sport=45678 dport=80, payload
```

Total GUE header for this packet = 4 (base) + 4 (private_type/next_hop/hop_count) +
4 (one hop) = **12 bytes** of tunnel header between the outer UDP and the inner IP.

## 6. The UDP source port = the hash (ECMP / RSS spreading)

The director sets the outer **UDP source port** to a value derived from the flow's
hash ([`glb_encap.c:163`](../../src/glb-director/glb_encap.c)):

```c
udp_hdr->src_port = htons(0x8000 | ((pkt_hash ^ flow_hash) & 0x7fff));
```

- `pkt_hash` = `siphash24(secure_key, src_ip)` (the same hash that picked the row).
- `flow_hash` = a hint from the inner flow (for TCP/UDP, effectively the **source
  port**).
- The result is masked to 15 bits and **OR'd with `0x8000`** (the high bit), so the
  port is always in the upper half (looks ephemeral, avoids clashing with real
  service ports).

**Why:** a datacenter switch does **ECMP** (Equal-Cost Multi-Path) — it hashes the
outer 5-tuple to pick one of several parallel paths, and a NIC uses **RSS** to spread
flows across RX queues. If every flow had the same UDP src port, they'd all hash to
the *same* path/queue (a hotspot). By making the UDP src port a per-flow hash value,
flows are **evenly spread** across paths and queues — but *consistently per flow*, so
a single TCP flow never reorders (reordering would stall TCP).

> **Analogy:** it's `shard_id = hash(key) % num_shards` to distribute load across
> shards, but computed into a *port number* so the *network fabric itself* (switches
> + NICs) does the distribution for free, no software round-trip.

## 7. The director's encap path (code walkthrough)

[`src/glb-director/glb_encap.c`](../../src/glb-director/glb_encap.c), function
`glb_encapsulate_packet()` — called per packet on the worker lcore:

1. **Route the packet** (done earlier in `glb_calculate_packet_route`):
   - `glb_extract_packet_fields()` reads the inner 5-tuple + IP version into a
     `route_context` (gives `flow_hash_hint`, `gue_ipproto`, `ip_total_length`).
   - `glb_add_packet_route()` computes `pkt_hash = siphash24(key, src_ip)`, does
     `row = pkt_hash & 0xffff`, reads `table->entries[row]` → `primary`, `secondary`,
     and appends both to `route_context->ipv4_hops[]` (`hop_count` becomes 2).
2. **Write the outer headers** (the function body):
   - `eth_hdr->d_addr = gateway_ether_addr` (the ToR/bridge MAC), `s_addr = local`
     (director NIC MAC), `ether_type = IPv4`.
   - Outer IPv4: `src = local_ip` (outbound_src_ip), `dst = hops[0]` (the **primary**),
     `proto = UDP`, `total_length` = outer IP+UDP+GUE+remaining hops+inner, `DF` set.
   - Outer UDP: `src = hash` (§6), `dst = 19523`, `checksum = 0`.
   - GUE: `private_type=0`, `next_hop=0`, `hop_count = hops - 1`,
     `protocol = gue_ipproto`, `flags=0`, `hlen = 1 + (hops-1)`, and `memcpy` the
     **remaining** hops into `hops[]` (already network byte order).
3. The inner packet is already sitting right after the headers in the same mbuf —
   the director just **prepended** the outer headers (the mbuf had headroom reserved
   for exactly `ROUTE_CONTEXT_ENCAP_SIZE`). Nothing about the inner bytes changes.

> **Architect's note:** encapsulation here is a **pure prepend** into pre-allocated
> mbuf headroom — no copy of the payload, no allocation, one struct fill. That's why
> it's cheap enough to do at line rate. (mbufs & headroom → [05](./05-dpdk.md).)

## 8. What happens at the proxy (the other end)

When the primary receives the GUE packet:
1. **FOU decapsulates**: the kernel `fou` module (registered for UDP port `19523`)
   strips the outer IP+UDP+GUE and injects the **inner** IP packet into the local
   stack. FOU **ignores the GUE private data** (it doesn't need it).
2. The local stack now sees "an IP packet for the VIP." If it's a **SYN** or matches
   an **established local connection**, it's delivered to the app normally.
3. If it's **neither** (a packet for a connection whose state is on the *other*
   server), the **GLBREDIRECT iptables module** reads the GUE private-data hop list,
   picks `hops[next_hop]`, rewrites the outer dst to that hop, and **forwards it
   there** — the "second chance." (Full detail in
   [06](./06-kernel-redirect.md).)

So the **hop list in GUE private data is the stateless "retry" mechanism** that makes
drain/failover work without the director storing any per-flow state
([03 §6](./03-load-balancing.md)).

## 9. Verifying the format (how the smoke test does it)

The repo ships a **scapy binding** for GLB-GUE: `src/scapy-glb-gue/glb_scapy/`
defines a `GLBGUE` packet class and binds it to `UDP/19523 → inner IP/IPv6`. The
smoke test uses it to decode the director's output pcap and assert every field
(outer MAC/IP, UDP sport/dport, GUE `protocol`, `hop_count`, `hops`, and the inner
packet) against values it computed from the repo's *own* rendezvous reference
(`tests/rendezvous_table.py` + `siphash`). That cross-check — *the director's binary
table vs. the documented hashing* — is what makes the test meaningful.

```bash
# Decode a captured GUE packet by hand (in the lab venv):
python -c "from scapy.all import rdpcap,IP,UDP; import sys; sys.path.insert(0,'src/scapy-glb-gue'); from glb_scapy import GLBGUE; [print(p.summary(), p[GLBGUE].show()) for p in rdpcap('/tmp/glb-smoke/tx_dump.pcap')]"
```

## 10. Key takeaways

1. **Encapsulation** = wrap the whole original IP packet in a new IP+UDP envelope
   addressed to the primary; the inner packet stays byte-identical.
2. GLB uses **GUE over UDP** (dst port `19523`), chosen for a controllable UDP src
   port (ECMP/RSS spreading) and easy matching.
3. **GUE `protocol` = inner IP version** (4/41), *not* the L4 protocol. A classic
   gotcha.
4. The **GUE private data** carries GLB's **hop list** (`private_type=0`,
   `next_hop=0`, `hop_count`, `hops[]`). The **first** hop is the outer dst; the rest
   are the fallbacks. This in-band hop list is the stateless "second chance."
5. The **UDP src port = `0x8000 | (pkt_hash ^ flow_port) & 0x7fff`** — per-flow
   hash for ECMP/RSS spreading, consistent per flow (no reordering).
6. Encap is a **pure prepend into mbuf headroom** (no payload copy) — cheap at line
   rate. The proxy side is **FOU decap + GLBREDIRECT** (→ [06](./06-kernel-redirect.md)).
