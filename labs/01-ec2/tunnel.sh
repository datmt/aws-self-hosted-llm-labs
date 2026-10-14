#!/usr/bin/env bash
# blocking SSM port-forward localhost:8000 -> instance:8000
set -euo pipefail
cd "$(dirname "$0")"
exec aws ssm start-session --region "${AWS_REGION:-us-east-1}" \
  --target "$(terraform output -raw instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8000"],"localPortNumber":["8000"]}'
