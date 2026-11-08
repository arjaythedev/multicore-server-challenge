#!/usr/bin/env bash
set -euo pipefail

OBS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$OBS_DIR/.." && pwd)"

source "$OBS_DIR/modes.env"

MODE="${1:-$TRACE_MODE}"

: "${DATABASE_URL:?DATABASE_URL is required}"
: "${JWT_SECRET:?JWT_SECRET is required}"

export PORT HOST

case "$MODE" in
  off)
    unset NODE_OPTIONS
    echo "[conduit] tracing=off"
    ;;

  sampled|full)
    if [[ "$MODE" == "full" ]]; then
      if [[ "${ALLOW_FULL_TRACE:-0}" != "1" ]]; then
        echo "Full tracing requires ALLOW_FULL_TRACE=1" >&2
        exit 2
      fi

      RATIO="1.0"
    else
      RATIO="$TRACE_RATIO"
    fi

    export OTEL_SERVICE_NAME="conduit-node"
    export OTEL_NODE_RESOURCE_DETECTORS="env,host,os,process"
    export OTEL_RESOURCE_ATTRIBUTES="deployment.environment.name=benchmark"

    export OTEL_TRACES_EXPORTER="otlp"
    export OTEL_METRICS_EXPORTER="none"
    export OTEL_LOGS_EXPORTER="none"

    export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
    export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318"

    export OTEL_TRACES_SAMPLER="parentbased_traceidratio"
    export OTEL_TRACES_SAMPLER_ARG="$RATIO"

    export OTEL_NODE_ENABLED_INSTRUMENTATIONS="http,pg"
    export OTEL_LOG_LEVEL="warn"

    export NODE_OPTIONS="--experimental-loader=@opentelemetry/instrumentation/hook.mjs --import=@opentelemetry/auto-instrumentations-node/register"

    echo "[conduit] tracing=$MODE ratio=$RATIO"
    ;;

  *)
    echo "Unknown tracing mode: $MODE" >&2
    exit 2
    ;;
esac

cd "$APP_DIR"
exec node dist/cluster.js
