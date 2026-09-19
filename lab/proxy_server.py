#!/usr/bin/env python3
"""Tiny stand-in for the L7 tier (haproxy/nginx in production).

Serves on the VIP inside a proxy namespace and identifies itself in the
response body, so you can see with your eyes which proxy answered a request
that came through the GLB director.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", required=True)
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--name", required=True)
    args = ap.parse_args()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 (http.server naming)
            body = f"GLB proxy: {args.name} ({args.bind}:{args.port})\n".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt: str, *a) -> None:
            pass  # keep the log quiet

    ThreadingHTTPServer((args.bind, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
