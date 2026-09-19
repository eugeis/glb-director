#!/bin/bash
# Stop the GLB lab monitoring stack (grafana, prometheus, statsd-exporter) and the
# monitoring director/veth if they were started by the lab helpers.
set -uo pipefail
MON_BASE="${MON_BASE:-$HOME/dev/glb-monitor}"
RUN="$MON_BASE/run"

stop_pid() { # $1 = name
  local p; p="$(cat "$RUN/$1.pid" 2>/dev/null)"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null 2>&1; then
    kill "$p" 2>/dev/null; sleep 1
    kill -0 "$p" 2>/dev/null 2>&1 && kill -9 "$p" 2>/dev/null
    echo "stopped $1 (pid $p)"
  else
    echo "$1 not running"
  fi
  rm -f "$RUN/$1.pid"
}

stop_pid grafana
stop_pid prometheus
stop_pid statsd-exporter

# stop the monitoring director + veth (if started by run_director_for_monitoring.sh)
if pgrep -x glb-director >/dev/null 2>&1; then
  sudo pkill -x glb-director 2>/dev/null || true
  sleep 1
  sudo pkill -9 -x glb-director 2>/dev/null || true
  echo "stopped glb-director"
fi
sudo ip link del glbt_dpdk 2>/dev/null && echo "removed veth glbt_dpdk" || true
sudo rm -f /dev/hugepages/rtemap_* 2>/dev/null || true

echo "monitoring stack stopped."
