# 01 — Networking fundamentals (the layers, the address space, the flow key)

> Audience: a systems engineer who is fluent in Go/Rust and architecture but new to
> networking. Every concept is mapped to something you already know. When you've
> absorbed this file you will be able to read a raw packet hex-dump and say exactly
> where each byte came from — which is the prerequisite for understanding what
> `glb-director` does to a packet.

## 1. The core mental model: packets are nested envelopes

A network packet is just a sequence of bytes. Protocols are layered so that each
layer adds a small **header** in front of the data it received from the layer above.
On the wire, for an HTTP `GET` you actually have this nesting (outer → inner):

```
[Ethernet | IP | TCP | "GET / HTTP/1.1\r\n..."]
 \_______/  \___/  \___/  \_________________/
   L2       L3     L4        L7 (application)
```

This is exactly the same idea as:
- **Go:** an `http.Request` is wrapped by the transport, which is wrapped by the
  connection. You never touch the lower layers, but they exist and do real work.
- **Rust:** like a `Box<Bytes>` where each layer owns a prefix (the header) and a
  pointer into the rest (the payload). Or like middleware: each layer peels off /
  adds its header and passes the remainder down.

The key discipline: **each layer only understands its own header and treats the rest
as an opaque byte blob.** The Ethernet layer doesn't care that it's carrying a TCP
segment; it just moves "the bytes" from one MAC address to another. This
*opaque-payload* property is the single most important idea, because
**encapsulation (tunneling, see [04](./04-encapsulation-and-gue.md)) is just
"treat a whole packet as the opaque payload of a new packet."**

### The practical "OSI layers" (skip the dogma, keep the addresses)

| Layer | Name | One-line job | The address that identifies "who" at this layer |
|------:|--------|--------------------------------------|------------------------------------------------|
| 7 | App    | the bytes your program sends/receives | (path, headers — protocol-specific) |
| 4 | Transport | reliable/unreliable delivery, per-app multiplexing | **port** (16-bit) |
| 3 | Network | route across many hops to a logical destination | **IP address** (32/128-bit) |
| 2 | Link   | move a frame across ONE physical link | **MAC address** (48-bit) |
| 1 | Physical | bits / electrical signals | — |

`glb-director` lives at the **L3/L4 boundary**: it reads the IP (L3) and the
transport (L4) headers, decides which backend a flow belongs to, and re-wraps the
whole L3+ packet inside a new L3+L4+GUE envelope. It never touches L7.

## 2. The two address spaces: MAC (L2) vs IP (L3)

This is the #1 confusion for newcomers, so here it is precisely.

- **IP address** = a *global, logical* address. It says "deliver this to host X
  anywhere on the internet." It is like a **street address + postcode**: it has
  meaning across the whole world, and it can change without the building moving.
- **MAC address** = a *local, per-link* address. It says "on *this* physical (or
  virtual) link, hand the frame to the NIC with this ID." It's like a **rack U-slot
  on a specific switch port**: only meaningful within one link segment.

**Why do we need both?** Because a packet usually crosses many links to reach its
destination, and *each link has different local hardware*. The IP address stays
constant end-to-end (the logical destination never changes), but the MAC addresses
are **rewritten at every hop**: each router replaces the src/dst MAC with "my
uplink" / "the next router on this link." The IP is like the address on the outer
envelope that never changes; the MAC is like the "next courier" label that changes
at every depot.

> **Go/Rust analogy:** IP is the `Destination` in your RPC call. MAC is the
> *current socket peer* — it changes as the message bounces through proxies, but
> the logical destination is invariant.

An **Ethernet frame** (L2) carries, in order: `dst MAC (6B)`, `src MAC (6B)`,
`EtherType (2B)`, `payload`, `FCS`. The **EtherType** is a 16-bit tag that tells the
receiver what protocol the payload is: `0x0800` = IPv4, `0x86DD` = IPv6,
`0x0806` = ARP. (Think of it as a `Content-Type` header at the link layer.)

## 3. IP (L3): routing, subnets, CIDR

An **IPv4 header** (20 bytes minimum) has the fields you'll actually meet:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|Version|  IHL  |    ToS/DSCP   |         Total Length          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         Identification        |Flags|     Fragment Offset     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         Time to Live          | Protocol  |    Header Checksum|
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Source Address                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Destination Address                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- **`Protocol`** (1 byte) = the L4 type, the IP-layer's "Content-Type": `6` = TCP,
  `17` = UDP, `1` = ICMP. (This is the *L4* protocol — do not confuse it with the
  GUE `Proto/ctype` field, which is the *inner IP version*; see
  [04 §4](./04-encapsulation-and-gue.md).)
- **`Time to Live` (TTL)** = a hop counter, decremented by every router; when it
  hits 0 the packet is dropped (and an ICMP "time exceeded" is sent back — that's
  how `traceroute` works). It's a loop-prevention / lifetime bound, like a
  recursion depth limit.
- **`Header Checksum`** = corruption detection (see §6).

### Routing = longest-prefix-match over a table of CIDR ranges

A host/router forwards a packet by looking at its **destination IP** and finding the
most specific matching **routing table** entry. Entries are CIDR ranges → next hop:

```
default via 192.168.100.1 dev eth0        # 0.0.0.0/0 → send to gateway
192.168.100.0/24 dev veth0 proto kernel   # that subnet → send out veth0
```

**CIDR** = "Classless Inter-Domain Routing." A `/N` is just a **bit mask**: the top
`N` bits are the "network" (fixed), the rest are "host" (variable).
`192.168.100.0/24` means "the 256 addresses from `192.168.100.0` to
`192.168.100.255`." In Rust terms, a subnet is a `(base, mask)` pair and membership
is `(ip & mask) == (base & mask)` — a two-and-compare. A route is a **longest
prefix match** (the entry with the largest `N` that still matches), which is
implemented with a trie. You'll see the lab use `/32` (a single host) and `/24`
(256 hosts) a lot.

> **Why this matters for glb-director:** the director is effectively a router that
> *chooses the next hop by hash* (the backend) instead of by destination IP, then
> encapsulates. The "route" is precomputed per flow into a forwarding table (see
> [03](./03-load-balancing.md)).

## 4. Ports (L4): how one IP serves many apps

An IP address identifies a **host**; a **port** (16-bit, 0–65535) identifies a
**service/process on that host**. Together, `(IP, port)` is a **socket address** —
exactly the `sockaddr_in` you already know from `bind()`/`connect()`.

- **UDP** = connectionless, no ordering, no retransmission, no flow control. Just
  "here's a datagram, YOLO." Low overhead, but the receiver can drop/duplicate.
  UDP *is* the transport `glb-director` encapsulates into (GUE rides on UDP).
- **TCP** = a reliable, ordered, byte-stream connection with flow control,
  retransmission, and congestion control. It maintains per-connection state.

### The TCP connection is a state machine (you already know this)

TCP identifies a connection by the **5-tuple**:

```
(src_ip, src_port, dst_ip, dst_port, protocol)
```

and lives in states `SYN-SENT → SYN-RCVD → ESTABLISHED → FIN-WAIT → … → CLOSED`.
The **3-way handshake** opens it: `SYN` → `SYN-ACK` → `ACK`.

**This 5-tuple is THE "flow key" for `glb-director`.** The director hashes part of
it (specifically the source IP) to pick a backend, and the *stability* of that
mapping is what keeps a TCP connection glued to the same backend for its whole
life. When you read [03](./03-load-balancing.md) and [04](./04-encapsulation-and-gue.md),
"the flow" always means "this 5-tuple." The reason draining is subtle is *entirely*
because of this per-connection TCP state: you can't just move an `ESTABLISHED`
connection to another server without that server already knowing about it.

> **Go/Rust analogy:** the 5-tuple is the map key for a `HashMap<[u8;20], Conn>`
> of live connections. Draining a backend is "rehash a key to a new bucket *without
> dropping the in-flight value*." GLB's whole trick is doing that **without the
> director ever storing the map** — it reuses the map that already exists in each
> proxy's kernel TCP stack.

## 5. Why a load balancer needs to be "sticky" (the motivation for everything)

A client opens a TCP connection to the VIP, it lands on backend A (the connection
state now lives in A's kernel). All subsequent packets of that connection **must**
reach A, or A's kernel sees a packet for a connection it doesn't know and drops it
(TCP relies on the state it built during the handshake). So a load balancer must
guarantee **connection stickiness**: same 5-tuple → same backend, for the whole
connection. The moment you scale backends (add/remove), naive schemes break
existing connections. **That problem is the entire reason `glb-director` exists**,
and [03](./03-load-balancing.md) is dedicated to it.

## 6. Checksums: corruption detection, not security

- **IP header checksum** (16-bit one's-complement sum of the header) and
  **UDP checksum** (covers the pseudo-header + payload) exist to catch bit flips in
  transit. They are *not* cryptographic; they won't stop tampering, only detect
  accidental corruption.
- The UDP checksum is optional (can be 0 = disabled) — another UDP "YOLO" trait.
- You can think of them as a cheap `crc16` over a slice. When you read a hex-dump
  and "verify" a checksum you're recomputing that sum and comparing.

> In the lab you mostly *trust* the checksums (the NIC/hardware validate them) and
> focus on the header *fields*. But knowing they exist explains why a corrupted
> frame shows up as an `rx_errors` counter (see [07](./07-observability.md)).

## 7. Wire format & endianness (the gotcha that bites everyone)

Networks use **big-endian** ("network byte order") for multi-byte integer fields.
x86 is little-endian, so when DPDK/C code reads a 16/32-bit field off a packet it
must byte-swap it (`rte_be_to_cpu_16/32`, the C equivalent of `.from_be`/`.to_be` in
Rust, or `binary.BigEndian.Uint16` in Go).

- A UDP source port of `61139` is stored on the wire as bytes `0xEF 0x8B`, not
  `0x8B 0xEF`.
- **This is why the lab's GUE source-port assertion can "look wrong" if you forget
  the byte order.** The smoke test decodes with scapy (which handles endianness for
  you), which is why it passes; a hand-rolled C parser that forgets `be_to_cpu` will
  not.

**How to read a hex-dump** (you'll do this in Wireshark / `tcpdump`): read left to
right, top to bottom; each row is 16 bytes with a hex offset on the left and an
ASCII gutter on the right. Match the field layout diagrams in this doc set against
the bytes. Example: the first 14 bytes of an Ethernet frame are
`dstMAC(6) srcMAC(6) ethertype(2)`.

## 8. Putting it together: what a glb-director packet looks like, layer by layer

A raw client packet arrives:

```
[Eth | IPv4(src=client, dst=VIP, proto=TCP) | TCP(src=45678, dst=80) | payload]
```

The director:
1. Reads the L4/L3 headers → derives the **flow key** (the 5-tuple) → hashes
   `src_ip` → looks up the forwarding-table row → gets **primary** (backend A) and
   **secondary** (backend B).
2. Wraps the *entire original IP packet* (steps 3–4 unchanged) inside a new
   envelope, addressed to the primary:

```
[Eth(dst=proxy_mac) | IPv4(src=director, dst=primary_A) |
 UDP(src=hash, dst=19523) | GUE(proto=4, hops=[primary_A, secondary_B]) |
   IPv4(src=client, dst=VIP, proto=TCP) | TCP(src=45678, dst=80) | payload ]
 ^ new outer L2/L3/L4                 ^ GUE private data = the "second chance" hop list
                                              ^ the original packet, untouched
```

That nesting — *a packet inside a packet, with a hint (the hop list) riding in the
GUE private data* — is the whole mechanism. You now have the vocabulary to follow
[04](./04-encapsulation-and-gue.md) (the exact byte layout) and
[06](./06-kernel-redirect.md) (how the proxy uses that hop list).

## 9. Commands to build the reflexes (run these in the lab)

```bash
# See the host's interfaces, MACs, IPs (the "L2/L3 address book")
ip -brief link
ip -brief addr

# See the routing table (CIDR → next hop)
ip route

# Grab a few packets on the client-facing veth and watch the headers
sudo tcpdump -i <veth> -nn -vv -c 5

# Decode one packet verbosely (L2/L3/L4 fields, checksums)
sudo tcpdump -i <veth> -nn -vv -s0 -c 1 'udp port 19523'
```

`tcpdump -vv` prints each header field in human form; `-s0` means "capture the full
packet, don't truncate." This is your first tool for *seeing* the layers you just
read about. For full packet *visualization*, see [07 §5](./07-observability.md).

## 10. Key takeaways (the 6 things to retain)

1. Packets are **nested envelopes**; each layer owns a header and treats the rest
   as opaque bytes. Encapsulation = a packet as another packet's payload.
2. **IP** = global logical destination (invariant end-to-end). **MAC** = local
   per-link address (rewritten every hop). You need both because paths have many links.
3. **Routing = longest-prefix-match** over CIDR (bit-mask) ranges → next hop.
4. **Port** = which app on a host. `(IP, port)` = a socket. UDP = no guarantees;
   TCP = reliable ordered stateful connection.
5. The **5-tuple** is the *flow key*. TCP connection state lives on the backend.
   **Stickiness** (same 5-tuple → same backend) is the problem a load balancer must solve.
6. The wire is **big-endian**; decode with byte-swap helpers or you'll read ports
   and IPs backwards.
