#!/usr/bin/env bash
# usage: bench-run.sh <model> [<model>...]
# Applies labs/01-ec2 with the first model, runs bench.sh ON the instance via SSM for each model
# (swapping the container between models, image stays cached), ALWAYS destroys.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
region=${AWS_REGION:-us-east-1}
out=$root/runs/01-ec2-bench/$(date +%Y%m%dT%H%M%S)
tf=(terraform -chdir="$root/labs/01-ec2")
tmp=$(mktemp -d); mkdir -p "$out"
mark() { echo "$(date -u +%FT%TZ) $*" | tee -a "$out/timeline.txt"; }

cleanup() {
  mark "destroy start"; d0=$(date +%s)
  "${tf[@]}" destroy -auto-approve -input=false >"$out/destroy.log" 2>&1
  mark "destroy end rc=$? duration=$(( $(date +%s) - d0 ))s"
  aws resourcegroupstaggingapi get-resources --region "$region" --tag-filters Key=lab,Values=01-ec2 \
    --query 'ResourceTagMappingList[].ResourceARN' --output text >"$out/leftovers.txt" 2>&1
  mark "leftovers: $(wc -w <"$out/leftovers.txt") (tag index lags; verify real state)"
  rm -rf "$tmp"
}
trap cleanup EXIT

ssm_run() { # $1 = local script; prints remote stdout; exit 0 only if remote succeeded
  local p c st
  p=$(python3 -c 'import json,sys,base64
s=open(sys.argv[1],"rb").read()
print(json.dumps({"commands":["echo "+base64.b64encode(s).decode()+" | base64 -d | bash"],"executionTimeout":["3000"]}))' "$1")
  c=$(aws ssm send-command --region "$region" --instance-ids "$id" --document-name AWS-RunShellScript \
        --parameters "$p" --query Command.CommandId --output text) || return 1
  while :; do
    st=$(aws ssm get-command-invocation --region "$region" --command-id "$c" --instance-id "$id" --query Status --output text 2>/dev/null)
    case $st in Pending|InProgress|Delayed|"") sleep 10;; *) break;; esac
  done
  aws ssm get-command-invocation --region "$region" --command-id "$c" --instance-id "$id" \
    --query StandardOutputContent --output text
  [ "$st" = Success ]
}

mark "apply start model=$1"
"${tf[@]}" init -input=false >"$out/apply.log" 2>&1
"${tf[@]}" apply -auto-approve -input=false -var "model=$1" >>"$out/apply.log" 2>&1 || { mark "apply FAILED"; exit 1; }
id=$("${tf[@]}" output -raw instance_id)
mark "apply end instance=$id"

for _ in $(seq 1 60); do # up to 10 min for the SSM agent
  [ "$(aws ssm describe-instance-information --region "$region" --filters Key=InstanceIds,Values="$id" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" = Online ] && break
  sleep 10
done
mark "ssm online"

first=1
for m in "$@"; do
  slug=$(tr '/' '_' <<<"$m")
  {
    echo 'set -u'
    if [ $first = 0 ]; then
      echo 'img=$(docker ps -a --format "{{.Image}}" | grep vllm | head -1)'
      echo 'docker rm -f $(docker ps -aq) >/dev/null'
      echo "docker run -d --gpus all --ipc=host -p 8000:8000 -e VLLM_USE_FLASHINFER_SAMPLER=0 \$img --model $m --dtype half --max-model-len 2048 >/dev/null"
    fi
    echo 'for i in $(seq 1 240); do curl -sf localhost:8000/health >/dev/null && { echo "ready after ${i}0s"; break; }; sleep 10; done'
    echo 'curl -sf localhost:8000/health >/dev/null || { echo NOT_READY; docker logs $(docker ps -aq | head -1) 2>&1 | tail -30; exit 1; }'
    cat "$root/tests/bench.sh"
  } >"$tmp/run.sh"
  first=0
  mark "bench start model=$m"
  if ssm_run "$tmp/run.sh" >"$out/bench-$slug.txt" 2>&1; then mark "bench done model=$m"; else mark "bench FAILED model=$m (see bench-$slug.txt)"; fi
  sed 's/^/    /' "$out/bench-$slug.txt" | tee -a "$out/timeline.txt" >/dev/null
  if grep -q "errors (count" "$out/bench-$slug.txt"; then   # keep the server's side of the story
    echo 'docker logs $(docker ps -aq | head -1) 2>&1 | grep -vE "GET /(health|v1/models)" | tail -150' >"$tmp/logs.sh"
    ssm_run "$tmp/logs.sh" >"$out/server-$slug.log" 2>&1 && mark "request errors seen; server log saved: server-$slug.log"
  fi
done
