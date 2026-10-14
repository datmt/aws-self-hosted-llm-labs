#!/usr/bin/env bash
# usage: e2e.sh <lab>  — apply, wait healthy, smoke x3, capture, ALWAYS destroy, leftovers.
# Output: runs/<lab>/<ts>/{timeline.txt,apply.log,smoke.log,server.log,destroy.log,leftovers.txt}
set -uo pipefail
lab=$1
root=$(cd "$(dirname "$0")/.." && pwd)
port=${PORT:-8000}
region=${AWS_REGION:-us-east-1}
out=$root/runs/$lab/$(date +%Y%m%dT%H%M%S)
tf=(terraform -chdir="$root/labs/$lab")
mkdir -p "$out"
now() { date +%s; }
mark() { echo "$(date -u +%FT%TZ) $*" | tee -a "$out/timeline.txt"; }

tp=
cleanup() {
  [ -n "$tp" ] && kill "$tp" 2>/dev/null
  mark "destroy start"; d0=$(now)
  "${tf[@]}" destroy -auto-approve -input=false >"$out/destroy.log" 2>&1
  mark "destroy end rc=$? duration=$(( $(now) - d0 ))s"
  aws resourcegroupstaggingapi get-resources --region "$region" --tag-filters Key=lab,Values="$lab" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text >"$out/leftovers.txt" 2>&1
  mark "leftovers: $(wc -w <"$out/leftovers.txt") resources (see leftovers.txt)"
}
trap cleanup EXIT

mark "apply start"; t0=$(now)
"${tf[@]}" init -input=false >"$out/apply.log" 2>&1
"${tf[@]}" apply -auto-approve -input=false >>"$out/apply.log" 2>&1 || { mark "apply FAILED"; exit 1; }
mark "apply end duration=$(( $(now) - t0 ))s"

# wait for /health; (re)start tunnel until it holds (SSM agent registers late)
t1=$(now); healthy=0
for n in $(seq 1 240); do
  if ! { [ -n "$tp" ] && kill -0 "$tp" 2>/dev/null; }; then
    LOCAL_PORT=$port "$root/labs/$lab/tunnel.sh" >/dev/null 2>&1 & tp=$!
  fi
  if curl -sf --max-time 5 localhost:$port/health >/dev/null; then healthy=1; break; fi
  [ $((n % 12)) -eq 0 ] && kill "$tp" 2>/dev/null # stale SSM session: reopen
  sleep 10
done
[ $healthy = 1 ] || { mark "never healthy after $(( $(now) - t1 ))s"; exit 1; }
mark "first health 200 after_apply=$(( $(now) - t1 ))s total=$(( $(now) - t0 ))s"

for i in 1 2 3; do
  echo "== smoke run $i" >>"$out/smoke.log"
  "$root/tests/smoke.sh" http://localhost:$port >>"$out/smoke.log" 2>&1 || mark "smoke run $i FAILED"
done
grep -E "chat ok" "$out/smoke.log" | tee -a "$out/timeline.txt"

# server-side evidence via SSM run-command: nvidia-smi + container log
id=$("${tf[@]}" output -raw instance_id 2>/dev/null || aws autoscaling describe-auto-scaling-groups --region "$region" \
  --auto-scaling-group-names "$("${tf[@]}" output -raw asg_name)" --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
cmd=$(aws ssm send-command --region "$region" --instance-ids "$id" --document-name AWS-RunShellScript \
  --parameters 'commands=["nvidia-smi","docker ps --format {{.Image}}","docker logs $(docker ps -q | head -1) 2>&1 | tail -60"]' \
  --query Command.CommandId --output text)
sleep 8
aws ssm get-command-invocation --region "$region" --command-id "$cmd" --instance-id "$id" \
  --query StandardOutputContent --output text >"$out/server.log" 2>&1
mark "capture done instance=$id"
