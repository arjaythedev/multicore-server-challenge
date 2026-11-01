#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

OBS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$OBS_DIR")"
RUNS_DIR="$OBS_DIR/runs"

source "$OBS_DIR/modes.env"

PORT="${PORT:-3110}"
HOST="${HOST:-0.0.0.0}"
TRACE_RATIO="${TRACE_RATIO:-0.05}"

export PORT HOST

usage() {
  cat <<'HELP'
Usage:
  ./ctl.sh stack start|stop|status|logs
  ./ctl.sh status
  ./ctl.sh sql on|off|detailed|status

  ./ctl.sh run baseline RUN_ID
  ./ctl.sh run sql RUN_ID
  ./ctl.sh run trace5 RUN_ID
  ./ctl.sh run trace100 RUN_ID
  ./ctl.sh run cpu RUN_ID
  ./ctl.sh run deep RUN_ID

  ./ctl.sh begin RUN_ID
  ./ctl.sh end RUN_ID
  ./ctl.sh report RUN_ID

Node.js runs in the foreground. Stop with Ctrl+C.
HELP
}

validate_id() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]] || {
    echo "Invalid RUN_ID: $1" >&2
    exit 2
  }
}

pg_track() {
  sudo -u postgres psql -X -A -t \
    -d conduit_lg \
    -c "SHOW pg_stat_statements.track;"
}

stack() {
  case "${1:-}" in
    start)
      sudo docker compose -f "$OBS_DIR/compose.yaml" up -d
      ;;
    stop)
      sudo docker compose -f "$OBS_DIR/compose.yaml" stop
      ;;
    status)
      sudo docker compose -f "$OBS_DIR/compose.yaml" ps
      ;;
    logs)
      sudo docker compose -f "$OBS_DIR/compose.yaml" \
        logs --tail=100 lgtm
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

status() {
  echo "=== Application ==="
  if curl -fsS --max-time 3 -o /dev/null \
      "http://127.0.0.1:$PORT/api/tags"; then
    echo "HTTP API: healthy"
  else
    echo "HTTP API: unavailable"
  fi

  echo
  echo "=== PostgreSQL ==="
  echo "pg_stat_statements.track: $(pg_track)"

  echo
  echo "=== Grafana ==="
  if curl -fsS --max-time 3 -o /dev/null \
      http://127.0.0.1:3300/api/health; then
    echo "LGTM: reachable"
  else
    echo "LGTM: unavailable"
  fi

  echo
  echo "=== Listening port ==="
  ss -H -ltn "( sport = :$PORT )"
}

run_app() {
  local mode="${1:?Missing mode}"
  local run_id="${2:?Missing RUN_ID}"
  local sql_mode
  local tracing="off"
  local cpu="off"
  local ratio="$TRACE_RATIO"

  validate_id "$run_id"

  case "$mode" in
    baseline)
      sql_mode="off"
      ;;
    sql)
      sql_mode="on"
      ;;
    trace5)
      sql_mode="on"
      tracing="on"
      ;;
    trace100)
      sql_mode="on"
      tracing="on"
      ratio="1.0"
      [[ "${ALLOW_FULL_TRACE:-0}" == "1" ]] || {
        echo "Set ALLOW_FULL_TRACE=1 to enable 100% tracing" >&2
        exit 2
      }
      ;;
    cpu)
      sql_mode="on"
      cpu="on"
      ;;
    deep)
      sql_mode="on"
      tracing="on"
      cpu="on"
      ;;
    *)
      echo "Unknown run mode: $mode" >&2
      usage
      exit 2
      ;;
  esac

  [[ -f "$OBS_DIR/runtime.env" ]] || {
    echo "Missing observability/runtime.env" >&2
    exit 2
  }

  [[ -f "$APP_DIR/dist/cluster.js" ]] || {
    echo "Missing dist/cluster.js; run npm run build" >&2
    exit 2
  }

  if ss -H -ltn "( sport = :$PORT )" | grep -q .; then
    echo "Port $PORT is occupied. Stop the old Node.js first." >&2
    exit 2
  fi

  if [[ "$tracing" == "on" ]]; then
    curl -fsS --max-time 3 -o /dev/null \
      http://127.0.0.1:3300/api/health || {
        echo "LGTM unavailable; run: ./ctl.sh stack start" >&2
        exit 2
      }
  fi

  local run_dir="$RUNS_DIR/$run_id"
  mkdir -p "$run_dir"

  [[ ! -e "$run_dir/manifest.txt" ]] || {
    echo "RUN_ID already used: $run_id" >&2
    exit 2
  }

  "$OBS_DIR/sql-profile.sh" "$sql_mode"

  {
    printf 'run_id=%s\n' "$run_id"
    printf 'mode=%s\n' "$mode"
    printf 'sql_mode=%s\n' "$sql_mode"
    printf 'tracing=%s\n' "$tracing"
    printf 'trace_ratio=%s\n' "$ratio"
    printf 'cpu_profiler=%s\n' "$cpu"
    printf 'port=%s\n' "$PORT"
    printf 'timestamp_utc=%s\n' "$(date -u +%FT%TZ)"
    printf 'node_version=%s\n' "$(node -v)"
    printf 'git_sha=%s\n' "$(git -C "$APP_DIR" rev-parse HEAD)"
    if [[ -n "$(git -C "$APP_DIR" status --porcelain)" ]]; then
      printf 'git_dirty=yes\n'
    else
      printf 'git_dirty=no\n'
    fi
  } > "$run_dir/manifest.txt"

  cd "$APP_DIR"

  # Ensure baseline does not inherit OTel preload.
  unset NODE_OPTIONS
  export OTEL_SDK_DISABLED=true

  local -a node_args=(
    "--env-file=$OBS_DIR/runtime.env"
  )

  if [[ "$tracing" == "on" ]]; then
    export OTEL_SDK_DISABLED=false
    export OTEL_SERVICE_NAME="conduit-node"
    export OTEL_RESOURCE_ATTRIBUTES="benchmark.run_id=$run_id,deployment.environment.name=benchmark"
    export OTEL_NODE_RESOURCE_DETECTORS="env,host,os,process"

    export OTEL_TRACES_EXPORTER="otlp"
    export OTEL_METRICS_EXPORTER="none"
    export OTEL_LOGS_EXPORTER="none"

    export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
    export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318"

    export OTEL_TRACES_SAMPLER="parentbased_traceidratio"
    export OTEL_TRACES_SAMPLER_ARG="$ratio"
    export OTEL_NODE_ENABLED_INSTRUMENTATIONS="http,pg"
    export OTEL_LOG_LEVEL="warn"

    export NODE_OPTIONS="--experimental-loader=@opentelemetry/instrumentation/hook.mjs --import=@opentelemetry/auto-instrumentations-node/register"
  fi

  if [[ "$cpu" == "on" ]]; then
    mkdir -p "$run_dir/cpu"
    node_args+=(
      "--cpu-prof"
      "--cpu-prof-dir=$run_dir/cpu"
    )
  fi

  echo
  echo "[conduit] RUN_ID=$run_id"
  echo "[conduit] mode=$mode sql=$sql_mode trace=$tracing cpu=$cpu"
  echo "[conduit] port=$PORT workers=6"
  echo "[conduit] Ctrl+C to stop"
  echo

  exec node "${node_args[@]}" dist/cluster.js
}

action="${1:-help}"
shift || true

case "$action" in
  stack)
    stack "${1:-}"
    ;;
  status)
    status
    ;;
  sql)
    case "${1:-}" in
      status) pg_track ;;
      on|off|detailed) "$OBS_DIR/sql-profile.sh" "$1" ;;
      *) usage; exit 2 ;;
    esac
    ;;
  run)
    run_app "${1:-}" "${2:-}"
    ;;
  begin)
    validate_id "${1:?Missing RUN_ID}"
    "$OBS_DIR/sql-snapshot.sh" begin "$1"
    ;;
  end)
    validate_id "${1:?Missing RUN_ID}"
    "$OBS_DIR/sql-snapshot.sh" end "$1"
    python3 "$OBS_DIR/sql-diff.py" "$1"
    ;;
  report)
    validate_id "${1:?Missing RUN_ID}"
    python3 "$OBS_DIR/sql-diff.py" "$1"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
