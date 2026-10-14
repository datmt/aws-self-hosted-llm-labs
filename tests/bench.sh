#!/usr/bin/env bash
# usage: bench.sh [base_url]  — run ON the serving host so the SSM tunnel is not in the numbers.
# Needs only bash, curl, awk. Uses ignore_eos so every request generates exactly TOK tokens.
set -euo pipefail
URL=${1:-http://localhost:8000}
TOK=${TOK:-256}
model=$(curl -sf "$URL/v1/models" | grep -o '"id": *"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$model" ] || { echo "bench: cannot read model id from $URL/v1/models"; exit 1; }

req() { # $1 = max_tokens -> "<http_code> <time_total>" (curl -w prints a time even for errors, so keep the code)
  curl -s -o /dev/null -w '%{http_code} %{time_total}\n' "$URL/v1/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$model\",\"prompt\":\"Write a long story about a robot who learns to paint.\",\"max_tokens\":$1,\"temperature\":0,\"ignore_eos\":true}"
}
ok_times() { awk '$1==200{print $2}'; }   # only successful requests count
median() { sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

echo "model: $model"
command -v nvidia-smi >/dev/null && echo "gpu: $(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader)"
for _ in 1 2 3; do req 16 >/dev/null; done # warm-up (first requests are slow: lazy init)

# single stream: max_tokens=1 ~ time to first token; (TOK-1)/(t_TOK - t_1) = decode speed
t1=$(for _ in 1 2 3 4 5 6 7; do req 1; done | ok_times | median)
tn=$(for _ in 1 2 3; do req "$TOK"; done | ok_times | median)
awk -v t1="$t1" -v tn="$tn" -v n="$TOK" 'BEGIN{
  printf "ttft_ms: %.0f\nsingle_stream_decode_tok_s: %.1f\nsingle_request_%d_tokens_s: %.2f\n", t1*1000, (n-1)/(tn-t1), n, tn}'

# aggregate throughput under concurrency (2 rounds, best kept)
echo "concurrency  ok  agg_tok_s"
for c in 1 8 32; do
  best=0; okn=0
  for _ in 1 2; do
    f=$(mktemp); t0=$(date +%s.%N)
    for _ in $(seq "$c"); do req "$TOK" >>"$f" & done
    wait
    t1e=$(date +%s.%N); n=$(awk '$1==200' "$f" | wc -l)
    bad=$(awk '$1!=200{print $1}' "$f" | sort | uniq -c | tr -s ' \n' ' ')
    [ -n "$bad" ] && echo "  c=$c errors (count code): $bad"
    rm -f "$f"
    r=$(awk -v n="$n" -v t="$TOK" -v a="$t0" -v b="$t1e" 'BEGIN{printf "%.1f", n*t/(b-a)}')
    if awk -v r="$r" -v b="$best" 'BEGIN{exit !(r>b)}'; then best=$r; okn=$n; fi
  done
  echo "$c  $okn/$c  $best"
done
