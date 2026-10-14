#!/usr/bin/env bash
# usage: smoke.sh [base_url]  — health, models, one chat call, latency + tokens/s
set -euo pipefail
URL=${1:-http://localhost:8000}

curl -sf "$URL/health" && echo "health ok"
curl -sf "$URL/v1/models" | grep -q 'Qwen2.5-0.5B-Instruct' && echo "models ok"

t0=$(date +%s.%N)
out=$(curl -sf "$URL/v1/chat/completions" -H 'Content-Type: application/json' -d '{
  "model": "Qwen/Qwen2.5-0.5B-Instruct",
  "messages": [{"role": "user", "content": "Say hello in five words."}],
  "temperature": 0, "max_tokens": 32}')
t1=$(date +%s.%N)

echo "$out"
grep -Eq '"content": ?"[^"]' <<<"$out" || { echo "FAIL: empty completion"; exit 1; }
tok=$(grep -o '"completion_tokens": *[0-9]*' <<<"$out" | grep -o '[0-9]*$')
awk -v a="$t0" -v b="$t1" -v n="$tok" 'BEGIN{d=b-a; printf "chat ok: %d tokens in %.2fs (%.1f tok/s)\n", n, d, n/d}'
