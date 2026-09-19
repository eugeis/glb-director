#!/usr/bin/env python3
"""Sustained traffic generator for the GLB monitoring demo.

Sends a steady stream of crafted client packets ("the flow") into the director's
veth peer so the *real* DPDK glb-director classifies + encapsulates them
continuously, producing a continuous stream of statsd metrics for the dashboard.

This is the demo equivalent of many real clients hitting the VIP. The director's
pcap-dumper TX writes the encapsulated packets to a file (ignored here); what we
care about is that the director's datapath runs, so statsd metrics flow.

Usage (run from the lab, with the director already up in dumper mode on glbt_dpdk):
  sudo python3 generate_traffic.py \
      --iface glbt_py --dst-mac <dpdk_mac> --src-mac <py_mac> \
      --src 10.11.12.13 --dst 10.0.0.1 --sport 45678 --dport 80 \
      --rate 200 --duration 600
"""

import argparse
import signal
import sys
import time


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface", required=True, help="veth peer to send from (e.g. glbt_py)")
    ap.add_argument("--dst-mac", required=True, help="MAC to address packets to (director veth MAC)")
    ap.add_argument("--src-mac", required=True, help="source MAC for the crafted frames")
    ap.add_argument("--src", default="10.11.12.13", help="inner source IP (the flow key)")
    ap.add_argument("--dst", default="10.0.0.1", help="inner destination IP (the VIP)")
    ap.add_argument("--sport", type=int, default=45678, help="inner TCP source port")
    ap.add_argument("--dport", type=int, default=80, help="inner TCP destination port")
    ap.add_argument("--payload", default="glb-monitor", help="inner TCP payload")
    ap.add_argument("--rate", type=int, default=200, help="packets/second to send")
    ap.add_argument("--duration", type=float, default=600.0, help="seconds to run (0 = until Ctrl-C)")
    ap.add_argument("--sources", default="", help="comma-sep extra source IPs to rotate (more flows)")
    args = ap.parse_args()

    from scapy.all import Ether, IP, TCP, sendp  # imported after arg parse

    sources = [args.src]
    if args.sources:
        sources += [s.strip() for s in args.sources.split(",") if s.strip()]

    stop = {"flag": False}

    def _sig(_s, _f):
        stop["flag"] = True

    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)

    inter = 1.0 / max(1, args.rate)
    deadline = time.time() + args.duration if args.duration > 0 else None
    sent = 0
    i = 0
    print(f"[traffic] iface={args.iface} rate={args.rate}pps sources={sources} "
          f"dst={args.dst}:{args.dport} duration={args.duration}s", flush=True)

    try:
        while not stop["flag"]:
            if deadline and time.time() >= deadline:
                break
            # send a small batch at the target inter-packet time
            batch = []
            for _ in range(min(20, max(1, args.rate // 10 or 1))):
                src = sources[i % len(sources)]
                i += 1
                pkt = (Ether(dst=args.dst_mac, src=args.src_mac)
                       / IP(src=src, dst=args.dst)
                       / TCP(sport=args.sport, dport=args.dport, flags="S")
                       / args.payload.encode())
                batch.append(pkt)
            sendp(batch, iface=args.iface, inter=inter, verbose=False)
            sent += len(batch)
    finally:
        print(f"[traffic] stopped after ~{sent} packets", flush=True)


if __name__ == "__main__":
    main()
