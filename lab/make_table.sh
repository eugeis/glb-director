#!/bin/bash
# Regenerate lab/forwarding_table.json + the binary table the director loads.
#
# usage: make_table.sh [P1_STATE [P2_STATE [P1_HEALTHY [P2_HEALTHY]]]]
#   state:    active | draining | filling | inactive
#   healthy:  true | false
#
# This is the manual form of what glb-healthcheck does in production: it
# rewrites backend state, then runs `glb-director-cli build-config`, which
# recomputes the 65536 rendezvous-hashed rows (see
# src/glb-director/cli/main.c and docs/development/glb-hashing.md).
set -euo pipefail
cd "$(dirname "$0")"

P1_STATE="${1:-active}"
P2_STATE="${2:-active}"
P1_HEALTHY="${3:-true}"
P2_HEALTHY="${4:-true}"

python3 - "$P1_STATE" "$P2_STATE" "$P1_HEALTHY" "$P2_HEALTHY" <<'EOF' > forwarding_table.json
import json, sys

s1, s2, h1, h2 = sys.argv[1:5]
print(json.dumps({
    "tables": [
        {
            "name": "lab1",
            "hash_key": "12345678901234561234567890123456",
            "seed": "34567890123456783456789012345678",
            "binds": [
                {"ip": "10.0.0.1", "proto": "tcp", "port": 80},
            ],
            "backends": [
                {"ip": "192.168.100.31", "state": s1, "healthy": h1 == "true"},
                {"ip": "192.168.100.32", "state": s2, "healthy": h2 == "true"},
            ],
        }
    ]
}, indent=2))
EOF

../src/glb-director/cli/glb-director-cli build-config \
    forwarding_table.json forwarding_table.bin

echo "built forwarding_table.bin (proxy1: $P1_STATE/$P1_HEALTHY, proxy2: $P2_STATE/$P2_HEALTHY)"
