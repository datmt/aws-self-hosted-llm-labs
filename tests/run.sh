#!/usr/bin/env bash
# usage: run.sh <lab>  — open lab tunnel, wait for /health, run smoke.sh, close tunnel
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
"$here/../labs/$1/tunnel.sh" >/dev/null 2>&1 &
trap 'kill $! 2>/dev/null || true' EXIT
for _ in $(seq 1 90); do   # up to 15 min: instance boot + image pull + model download
  curl -sf localhost:8000/health >/dev/null && break
  sleep 10
done
"$here/smoke.sh" http://localhost:8000
