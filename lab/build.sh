#!/bin/bash
# Build the lab live director.
#
# Links the lab's RX/TX wrapper (lab/live_director.c) with the repo's real
# encapsulation core:
#   src/glb-director/glb_encap.c            - route calc + GUE header build
#   src/glb-director/glb_fwd_config.c       - binary forwarding table loading
#   src/glb-director/glb_director_config.c  - director.conf (JSON) loading
#   src/glb-director/siphash24.c            - the hash used for flows
#   src/glb-director/shared_opt.c           - shared options/debug flag
#   src/glb-director/cmdline_parse_etheraddr.c
#
# PCAP_MODE is defined so the shared code skips DPDK-only bits (rte_acl
# classifiers, DPDK atomics), the same way the repo's cli/ pcap targets do.
set -euo pipefail
cd "$(dirname "$0")/.."

gcc -O2 -g -Wall -DPCAP_MODE \
    -Isrc/glb-director -Isrc \
    -I/usr/include/dpdk \
    -I/usr/include/x86_64-linux-gnu \
    -I/usr/include/x86_64-linux-gnu/dpdk \
    -pie -fPIE -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=1 -fstack-protector-strong \
    lab/live_director.c \
    src/glb-director/glb_encap.c \
    src/glb-director/glb_fwd_config.c \
    src/glb-director/glb_director_config.c \
    src/glb-director/siphash24.c \
    src/glb-director/shared_opt.c \
    src/glb-director/cmdline_parse_etheraddr.c \
    -o lab/live_director \
    -ljansson -z relro -z now

echo "built lab/live_director"
