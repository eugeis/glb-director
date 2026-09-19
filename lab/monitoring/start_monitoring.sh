#!/bin/bash
# Start the GLB lab monitoring stack:
#   statsd-exporter (UDP statsd :28125 -> Prometheus metrics :9102)
#   prometheus      (scrapes :9102, serves :9090)
#   grafana         (dashboards on :3002; override GRAF_PORT)
# and auto-provision the Prometheus datasource + the GLB dashboard in Grafana.
#
# Everything runs from ~/dev/glb-monitor (installed by the setup), with logs and
# state under ~/dev/glb-monitor/run. Nothing is installed system-wide.
#
# Env overrides:
#   STATS_D_PORT  (default 28125) - the UDP port the DIRECTOR sends statsd to.
#                                   The director's config statsd_port MUST match.
#   MON_BASE      (default $HOME/dev/glb-monitor)
set -uo pipefail

MON_BASE="${MON_BASE:-$HOME/dev/glb-monitor}"
RUN="$MON_BASE/run"
HERE="$(cd "$(dirname "$0")" && pwd)"
STATS_D_PORT="${STATS_D_PORT:-28125}"
EXP_WEB_PORT=9102
PROM_PORT=9090
# On this lab host the agent runtime already holds :3000/:3001, so the default is
# 3002 here; override with GRAF_PORT=<free port> if needed.
GRAF_PORT="${GRAF_PORT:-3002}"
GRAF_USER="admin"; GRAF_PASS="admin"

port_free() { ! ss -ltn 2>/dev/null | grep -qE "[:.]$1 "; }

mkdir -p "$RUN"

# --- locate the installed binaries (version-independent) ---------------------
PROM_BIN="$(ls "$MON_BASE/prometheus"/prometheus-*.linux-amd64/prometheus 2>/dev/null | head -1)"
# repo renamed to statsd_exporter (underscore) -> binary + dir use an underscore;
# accept either spelling and either dir name.
EXP_BIN="$(find "$MON_BASE/statsd-exporter" -maxdepth 2 -type f \( -name 'statsd_exporter' -o -name 'statsd-exporter' \) 2>/dev/null | head -1)"
GRAF_DIR="$(ls -d "$MON_BASE/grafana"/grafana-v* 2>/dev/null | head -1)"
GRAF_BIN="$GRAF_DIR/bin/grafana-server"
[ -x "$GRAF_BIN" ] || GRAF_BIN="$GRAF_DIR/bin/grafana"

for f in "$PROM_BIN" "$EXP_BIN" "$GRAF_BIN"; do
  [ -e "$f" ] || { echo "ERROR: missing $f - install the toolchain first (see README.md)"; exit 1; }
done
echo "prometheus:      $PROM_BIN"
echo "statsd-exporter: $EXP_BIN"
echo "grafana:         $GRAF_BIN"

is_up() { curl -sf "http://127.0.0.1:$1/$2" >/dev/null 2>&1; }
pid_of() { cat "$RUN/$1.pid" 2>/dev/null; }
already() { local p; p="$(pid_of "$1")"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p" && return 0; return 1; }

# --- statsd-exporter ----------------------------------------------------------
if P="$(already statsd-exporter)"; then echo "statsd-exporter already up (pid $P)";
else
  setsid "$EXP_BIN" \
    --statsd.listen-udp=":$STATS_D_PORT" \
    --web.listen-address=":$EXP_WEB_PORT" \
    --statsd.mapping-config="$HERE/statsd-exporter-mappings.yml" \
    > "$RUN/statsd-exporter.log" 2>&1 < /dev/null &
  echo $! > "$RUN/statsd-exporter.pid"
  echo "statsd-exporter: statsd UDP :$STATS_D_PORT -> metrics http://127.0.0.1:$EXP_WEB_PORT/metrics"
fi

# --- prometheus ---------------------------------------------------------------
if P="$(already prometheus)"; then echo "prometheus already up (pid $P)";
else
  setsid "$PROM_BIN" \
    --config.file="$HERE/prometheus.yml" \
    --storage.tsdb.path="$RUN/prom-data" \
    --web.listen-address=":$PROM_PORT" \
    > "$RUN/prometheus.log" 2>&1 < /dev/null &
  echo $! > "$RUN/prometheus.pid"
  echo "prometheus:      http://127.0.0.1:$PROM_PORT"
fi

# --- grafana ------------------------------------------------------------------
if P="$(already grafana)"; then echo "grafana already up (pid $P)";
else
  if ! port_free "$GRAF_PORT"; then
    echo "ERROR: Grafana port $GRAF_PORT is already in use (by another process)."
    echo "       Pick a free one, e.g.:  GRAF_PORT=3030 $0"
    exit 1
  fi
  ( cd "$GRAF_DIR" && \
    setsid env \
      GF_SERVER_HTTP_PORT="$GRAF_PORT" \
      GF_SERVER_ROOT_URL="http://localhost:$GRAF_PORT/" \
      GF_SECURITY_ADMIN_USER="$GRAF_USER" GF_SECURITY_ADMIN_PASSWORD="$GRAF_PASS" \
      GF_USERS_ALLOW_SIGN_UP=false \
      GF_PATHS_DATA="$RUN/grafana-data" GF_PATHS_LOGS="$RUN/grafana-logs" GF_PATHS_PLUGINS="$RUN/grafana-plugins" \
      "$GRAF_BIN" --homepath="$GRAF_DIR" --config="$GRAF_DIR/conf/defaults.ini" \
      > "$RUN/grafana.log" 2>&1 < /dev/null & echo $! > "$RUN/grafana.pid" )
  echo "grafana:         http://127.0.0.1:$GRAF_PORT  ($GRAF_USER/$GRAF_PASS)"
fi

# --- wait for grafana health --------------------------------------------------
echo "waiting for grafana to become ready ..."
for i in $(seq 1 60); do
  is_up "$GRAF_PORT" "api/health" && break
  sleep 1
done
if ! is_up "$GRAF_PORT" "api/health"; then
  echo "WARNING: grafana not ready yet (see $RUN/grafana.log); skipping auto-provisioning"
  exit 0
fi

# --- provision datasource + dashboard ----------------------------------------
AUTH="-u $GRAF_USER:$GRAF_PASS"
DS_BODY='{"name":"Prometheus (GLB)","type":"prometheus","access":"proxy","url":"http://127.0.0.1:9090","uid":"glb-prom","isDefault":true}'
code="$(curl -s -o /dev/null -w '%{http_code}' $AUTH -X POST \
  "http://127.0.0.1:$GRAF_PORT/api/datasources" -H 'Content-Type: application/json' -d "$DS_BODY")"
if [ "$code" = "400" ] || [ "$code" = "409" ] || [ "$code" = "412" ]; then
  curl -s $AUTH -X PUT "http://127.0.0.1:$GRAF_PORT/api/datasources/uid/glb-prom" \
    -H 'Content-Type: application/json' -d "$DS_BODY" >/dev/null
  echo "datasource 'Prometheus (GLB)' (uid glb-prom) updated"
else
  echo "datasource 'Prometheus (GLB)' (uid glb-prom) created (http $code)"
fi

python3 -c "import json;d=json.load(open('$HERE/grafana-dashboard-glb-director.json'));print(json.dumps({'dashboard':d,'overwrite':True}))" \
  > "$RUN/dash_import.json"
curl -s $AUTH -X POST "http://127.0.0.1:$GRAF_PORT/api/dashboards/db" \
  -H 'Content-Type: application/json' -d @"$RUN/dash_import.json" >/dev/null \
  && echo "dashboard 'GLB Director - datapath & failover' imported"

echo ""
echo "monitoring stack up:"
echo "  Grafana     http://localhost:$GRAF_PORT  ($GRAF_USER/$GRAF_PASS)  <- open this"
echo "  Prometheus  http://localhost:$PROM_PORT"
echo "  Exporter    http://localhost:$EXP_WEB_PORT/metrics"
echo ""
echo "Next: start the director (run_director_for_monitoring.sh) and traffic"
echo "      (generate_traffic.py). See lab/monitoring/README.md."
