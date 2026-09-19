#!/bin/bash
# Trigger a drain/failover event on the monitoring director: rebuild the
# forwarding table with the test flow's primary backend (192.168.100.21) marked
# `draining`, then SIGUSR1 the director (the same signal `systemctl reload` sends
# in production). The director hot-reloads the table; watch
# glb_director_core_config_reload_total tick in Grafana, and (with a long-lived
# connection) the flow re-route to the secondary.
#
# Run after run_director_for_monitoring.sh + generate_traffic.py.
set -uo pipefail

REPO="$HOME/dev/_forks/glb-director"
CLI="$REPO/src/glb-director/cli/glb-director-cli"
RUN="$HOME/dev/glb-monitor/run"; T="$RUN/monitor"

DPID="$(cat "$RUN/director.pid" 2>/dev/null || pgrep -x glb-director | head -1)"
# the director runs as root (started via sudo), so the liveness check needs sudo too.
[ -n "$DPID" ] && sudo kill -0 "$DPID" 2>/dev/null || { echo "no running glb-director found"; exit 1; }

[ -e "$T/config.json" ] || { echo "no monitoring table dir ($T) - run run_director_for_monitoring.sh first"; exit 1; }

# rebuild the table with 192.168.100.21 draining (the flow's primary), .20 active.
# `glb-director-cli build-config` re-reads and rewrites the SAME fwd.bin the
# director is watching; the director picks it up on SIGUSR1.
cat > "$T/table_drain.json" <<EOF
{
  "tables": [{
    "name": "monitor",
    "hash_key": "12345678901234561234567890123456",
    "seed": "34567890123456783456789012345678",
    "binds": [{ "ip": "10.0.0.1", "proto": "tcp", "port": 80 }],
    "backends": [
      { "ip": "192.168.100.20", "state": "active", "healthy": true },
      { "ip": "192.168.100.21", "state": "draining", "healthy": true }
    ]
  }]
}
EOF
"$CLI" build-config "$T/table_drain.json" "$T/fwd.bin"
echo "table rebuilt (192.168.100.21 draining); sending SIGUSR1 to $DPID"
sudo kill -USR1 "$DPID"

for i in $(seq 1 10); do
  grep -q "Reload requested" "$T/director.log" 2>/dev/null && { echo "reload acknowledged (see $T/director.log)"; break; }
  sleep 1
done

echo ""
echo "watch in Grafana: 'Table reloads' stat should increment by 1."
echo "To restore: re-run the healthy table:"
echo "  $CLI build-config <(echo '{\"tables\":[{\"name\":\"monitor\",\"hash_key\":\"12345678901234561234567890123456\",\"seed\":\"34567890123456783456789012345678\",\"binds\":[{\"ip\":\"10.0.0.1\",\"proto\":\"tcp\",\"port\":80}],\"backends\":[{\"ip\":\"192.168.100.20\",\"state\":\"active\",\"healthy\":true},{\"ip\":\"192.168.100.21\",\"state\":\"active\",\"healthy\":true}]}]}') $T/fwd.bin && sudo kill -USR1 $DPID"
