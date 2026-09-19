#!/bin/bash
# Change one backend's state and hot-reload the running director.
#
# usage: drain.sh proxy1 draining
#         drain.sh proxy2 active
#
# Rebuilds the forwarding table, then sends SIGUSR1 to the lab director -
# the same signal `systemctl reload glb-director` sends in production
# (see src/glb-director/glb_control_loop.c).
set -euo pipefail
cd "$(dirname "$0")"

which="${1:?usage: drain.sh proxy1|proxy2 <active|draining|filling|inactive>}"
state="${2:?usage: drain.sh proxy1|proxy2 <active|draining|filling|inactive>}"

case "$which" in
    proxy1) P1_STATE="$state"; P2_STATE=active ;;
    proxy2) P2_STATE="$state"; P1_STATE=active ;;
    *) echo "unknown proxy: $which" >&2; exit 1 ;;
esac

./make_table.sh "$P1_STATE" "$P2_STATE"

if sudo ip netns exec ns-director pgrep -x live_director >/dev/null 2>&1; then
    sudo ip netns exec ns-director pkill -USR1 -x live_director
    echo "signalled lab director to reload the new table"
else
    echo "WARNING: live_director not running; table rebuilt but not loaded"
fi
