#!/usr/bin/env python3
"""Hold a single TCP connection through the GLB director across a backend
drain, to observe what happens to an *established* connection whose primary
starts draining (see docs/learning/05-simulations.md, simulation B).

Usage (from the client namespace):
    sudo ip netns exec ns-client python3 lab/long_lived_client.py \
        --src 192.168.100.11 --sleep 25
"""

import argparse
import socket
import time


def read_response(s: socket.socket) -> str:
    buf = b""
    while True:
        head, sep, rest = buf.partition(b"\r\n\r\n")
        if sep:
            cl = 0
            for line in head.decode(errors="replace").split("\r\n"):
                if ":" in line:
                    k, _, v = line.partition(":")
                    if k.strip().lower() == "content-length":
                        cl = int(v.strip())
            if len(rest) >= cl:
                return rest[:cl].decode(errors="replace")
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    return "<connection closed>"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="source IP (one of the client's lab IPs)")
    ap.add_argument("--dst", default="10.0.0.1")
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--sleep", type=float, default=25.0)
    args = ap.parse_args()

    s = socket.create_connection((args.dst, args.port), source_address=(args.src, 0))
    print(f"[long-lived] connected {args.src} -> {args.dst}:{args.port}")

    def req(tag: str) -> None:
        s.sendall(f"GET / HTTP/1.1\r\nHost: lab\r\n\r\n".encode())
        print(f"[long-lived] {tag}: {read_response(s).strip()}")

    req("request-1 (before drain)")
    print(f"[long-lived] sleeping {args.sleep:.0f}s ... now drain the primary!")
    time.sleep(args.sleep)
    req("request-2 (after drain)")
    s.close()


if __name__ == "__main__":
    main()
