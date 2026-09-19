# 02 — Linux virtual networking (netns, veth, bridges) & the lab topology

> You've read [01](./01-networking-fundamentals.md). This file is about **how Linux
> builds a whole network out of software**, and exactly how the GLB lab is wired so
> you can run a "datacenter" (clients + director + proxies) on a single machine.
> Every box below is a concept you can create/inspect with the `ip` command.

## 1. The one idea: an "interface" is a first-class object

In Linux, *everything* network-ish is a **network interface** (`net_device`): a
real NIC (`eth0`), the loopback (`lo`), a bridge (`br0`), a veth end, a tunnel
(`tunl0`), a Wi-Fi radio, etc. Each interface has:
- a **MAC address** (its L2 identity),
- zero or more **IP addresses** (its L3 identity),
- a **state** (`UP`/`DOWN`),
- an **RX/TX path** into the kernel network stack.

The kernel's network stack is the same code path for a real NIC and a virtual one —
that's what makes virtual topologies "real": a packet sent into a veth is processed
by exactly the same routing/forwarding/conntrack code as a packet off a wire.

> **Go/Rust analogy:** an interface is like a `netlink`-registered resource with a
> `File`-like handle. You can create, configure, and delete them at runtime. `ip`
> is the CLI; under the hood it talks to the kernel over `netlink` sockets (a
> typed IPC channel — think of it as gRPC to the kernel's net subsystem).

## 2. Network namespaces: separate network stacks (the core abstraction)

A **network namespace** (`netns`) is an isolated copy of the entire network stack:
its own set of interfaces, its own routing table, its own iptables rules, its own
port space, its own `/proc/net/*`. Processes in one namespace **cannot see or talk
to** the interfaces of another unless you explicitly connect them.

Think of a netns as:
- a **`chroot`/container, but for networking** (you already know containers give
  process/CPU/memory isolation; a netns gives *network* isolation),
- or a **separate "network machine"** you can build a topology across.

Why this matters: **the entire GLB lab is 4 netns on one host** — `ns-client`,
`ns-director`, `ns-proxy1`, `ns-proxy2` — plus the host's own ("root") namespace
acting as the switch/router between them. One laptop = one datacenter.

```
ip netns add ns-proxy1            # create a namespace
ip netns exec ns-proxy1 ip addr   # run a command *inside* it
ip netns list                     # list them
```

## 3. veth pairs: a virtual Ethernet cable with two plugs

A **veth** (virtual Ethernet) device is always created in **pairs**. Each end is a
normal interface, but a frame written to one end is *delivered* to the other end —
exactly like a patch cable. One end typically lives in one namespace, the other in
another (or in a bridge). That's how you "wire" namespaces together.

```
ip link add veth-a type veth peer name veth-b
ip link set veth-a netns ns-x      # one plug goes into namespace x
# veth-b stays in the root ns      # the other plug stays here
```

> **Analogy:** a veth pair is a `channel`/pipe whose two ends are in different
> "processes" (namespaces). Write a frame to one end, the other end's stack
> receives it as if it came off the wire.

## 4. Bridges: a virtual L2 switch

A **bridge** (`br0`) is a software **Layer-2 switch**. You "port" interfaces onto
it (usually veth ends), and the bridge forwards frames between ports based on MAC
addresses (it *learns* which MAC is reachable via which port, exactly like a real
switch). It also has its **own MAC address** and can have its **own IP** (making it
a router/gateway too).

```
ip link add br0 type bridge
ip link set veth-a-br master br0   # attach a veth end as a port
ip link set br0 up
```

In the lab, `br0` is the **"ToR switch"** (top-of-rack). Every node's veth end
plugs into `br0`, so all nodes can talk L2 across the bridge. Because `br0` also
has an IP and the root namespace has `ip_forward=1`, the root namespace also acts
as the **L3 router/gateway** for the lab subnet — exactly what a real ToR switch +
router does.

## 5. Routing & gateways (recap, applied)

Each namespace has a routing table. A node sends a packet out the interface that
matches the most specific route for the destination, and if it's "via a gateway,"
it sets the dst MAC to the gateway's MAC and hands it to the link. The lab relies
on a few routes:
- **root ns:** `192.168.100.0/24 dev br0` → "the whole lab subnet lives behind
  br0," so any reply to a proxy/client is routed out the bridge.
- **client:** `10.0.0.1/32 via 192.168.100.20` → "the VIP is only reachable through
  the director's IP." This is the **key** route: it forces all VIP traffic through
  the director, which is the whole point of a load balancer (you hit one VIP, the
  director steers it).

## 6. The full GLB topology (`setup_topology.sh`)

This is the "rich" topology that exercises the *entire* system, including the
proxy-side decapsulation and second-chance redirect. The host's root namespace is
the ToR switch + router.

```
                 root netns  =  "ToR switch + router"
                 br0 (bridge, has a MAC + IP) + route 192.168.100.0/24 dev br0
                 ip_forward=1, rp_filter=0
        +----------------+----------------+----------------+
        |                |                |                |
   veth-client      veth-director     veth-proxy1      veth-proxy2
        |                |                |                |
   [ns-client]      [ns-director]     [ns-proxy1]      [ns-proxy2]
   .10 (+.11-.14)    .20             .31 + VIP         .32 + VIP
   route VIP        (director        on tunl0          on tunl0
    via .20          lives here)      FOU+GLBREDIRECT   FOU+GLBREDIRECT
```

What each piece does, and why:

- **`ns-client` (192.168.100.10, plus `.11`–`.14` as extra `/32` IPs):** the
  "users." Each extra source IP hashes to a *different* forwarding-table row, so
  you can generate different flows from one namespace. Its route
  `VIP/32 via .20` forces VIP traffic through the director. `ip_forward=0` (a
  client never forwards).
- **`ns-director` (192.168.100.20):** where the director sits, on `veth-director`.
  It sees the client's raw packets, classifies + encapsulates them into GLB-GUE
  addressed to a backend. `ip_forward=0` (the director is not a router; it
  rewrites and re-sends).
- **`ns-proxy1` / `ns-proxy2` (192.168.100.31 / .32):** the backends. Each:
  1. runs **FOU** decapsulation for GUE port `19523` (`ip fou add port 19523 gue`)
     — the kernel strips the UDP+GUE envelope and exposes the *inner* IP packet to
     the local stack (see [04 §5](./04-encapsulation-and-gue.md));
  2. **owns the VIP `10.0.0.1/32` on `tunl0`** — so a decapsulated inner packet
     "destined for 10.0.0.1" is *local* here and delivered to the app;
  3. runs the **GLBREDIRECT** iptables rule (the "second chance" — see
     [06](./06-kernel-redirect.md)) to forward a packet to the next hop when it
     isn't a local connection;
  4. `ip_forward=1` so it can re-route the second-chance packet out again.

**Two subtleties worth understanding:**

1. **Why is the GUE frame's dst MAC = br0's MAC?** The director sets the outer
   Ethernet dst to the `outbound_gateway_mac` (br0's MAC). A frame addressed to a
   bridge's *own* MAC is consumed by the bridge's owning namespace (the root ns),
   which then does normal **L3 routing** to the backend IP — exactly how a real ToR
   switch handles a frame sent to itself. This is what makes the "switch + router"
   collapse into one root namespace.
2. **Direct Server Return (DSR):** the *response* to a client does **not** go back
   through the director. Because the proxy owns the VIP on `tunl0`, it answers the
   client directly (its source = VIP, its reply routes back via the bridge). The
   director only handles the *request* direction. This is the classic DSR pattern:
   the LB is only in the forward path, so it doesn't become the bottleneck for
   response bytes. (This is why the topology disables `rp_filter` — the reply
   "comes from an unexpected interface," and strict reverse-path checks would drop
   it.)

## 7. The smoke-test topology (`smoke_dpdk_director.sh`) — simpler, real DPDK binary

The passing test does **not** build the 4-netns topology. It uses a **two-end veth**
and runs the *real* DPDK `glb-director` binary in **pcap-dumper mode**:

```
   [ python/scapy ]                [ real DPDK glb-director ]
        |  glbt_py  <------veth pair------>  glbt_dpdk  |
        |  (sends crafted         (eth_pcap vdev:        |
        |   client packet)         rx_iface=glbt_dpdk,   |
                                   tx_pcap=tx_dump.pcap) |
```

- `glbt_py` (python end): scapy sends a crafted client packet (the "5-tuple").
- `glbt_dpdk` (director end): the director's `eth_pcap` vdev **RX**es from this
  real veth and **TX**es to a **pcap file** (`tx_dump.pcap`) instead of a wire.
- We then **parse the pcap with scapy** (using the repo's `glb_scapy.GLBGUE`
  binding) and assert the *full* encapsulated wire format.

**Why dumper mode and not real wire TX?** On this lab host, the director's
`pcap_sendpacket` inside an EAL process does not reach the peer veth end (the
"pcap PMD TX quirk" — see [LEARNING.md §7](../LEARNING.md) and
[05 §9](./05-dpdk.md)). The dumper works around it *and* is actually better for a
unit test: it captures **byte-for-byte exactly what the director encapsulated**,
independent of any wire delivery quirk. The glb-director logic under test is the
*encapsulation*, which the dumper observes perfectly.

> **Note for monitoring:** the smoke test's director config sets
> `statsd_port: 8125`, so that director emits statsd to `127.0.0.1:8125`. The full
> lab's `live_director` writes a plain stats file instead. See
> [07](./07-observability.md) for how the two map onto the monitoring stack.

## 8. FOU in one paragraph (detail in [04](./04-encapsulation-and-gue.md))

**FOU** ("Foo over UDP") is a Linux kernel module that lets you say "UDP packets
arriving on port 19523 are actually carrying an IP tunnel." `ip fou add port 19523
gue` registers that. When a GUE packet hits the proxy, FOU strips the outer
IP+UDP+GUE and injects the **inner** IP packet into the local stack as if it arrived
on a real interface — *ignoring the GUE private data*. The private data (the hop
list) is read separately by the GLBREDIRECT iptables module. FOU is the
"decapsulation" half of the proxy side.

## 9. Commands to inspect a running topology

```bash
ip netns list                          # the namespaces
sudo ip netns exec ns-proxy1 ip -brief addr   # a ns's interfaces/IPs
sudo ip -s link show br0               # bridge + its ports (brif)
ls /sys/class/net/br0/brif             # which veth ends are ports of br0
ip route                               # root ns routes (br0 = the lab subnet)
sudo ip netns exec ns-client ip route  # client's VIP-via-director route
sudo ip fou show                       # FOU tunnels on the host
sudo ip netns exec ns-proxy1 ip fou show   # FOU inside a proxy
sudo ip netns exec ns-proxy1 iptables-save  # the GLBREDIRECT rules
```

`tcpdump` on `br0` (root ns) shows the **encapsulated** GUE frames in flight;
`tcpdump` inside a proxy shows the **decapsulated** inner packets. Watching both
side-by-side is the fastest way to *see* encapsulation happen.

## 10. Key takeaways

1. **Interface = first-class object** (MAC + IPs + state + RX/TX). Real and virtual
   interfaces go through the same kernel stack — that's what makes virtual
   topologies behave "for real."
2. **netns** = an isolated network stack (the container-of-networking). The lab is
   4 netns + the root ns as switch/router.
3. **veth pair** = a virtual cable (two ends, frame in one = frame out the other).
4. **bridge** = a software L2 switch; in the lab it's the **ToR**, and the root ns
   is also the **L3 gateway** (ip_forward=1).
5. **Routes** wire it together: the client's `VIP via director` route is what forces
   traffic through the LB; the root ns's `subnet dev br0` route is what delivers
   GUE frames to the right proxy.
6. **DSR**: responses skip the director (proxies own the VIP on `tunl0`); the LB is
   only in the request path.
7. **FOU** decapsulates GUE on the proxy; **GLBREDIRECT** (iptables) implements the
   second chance. (→ [04](./04-encapsulation-and-gue.md), [06](./06-kernel-redirect.md))
