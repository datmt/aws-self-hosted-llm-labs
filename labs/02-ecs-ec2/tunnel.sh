#!/usr/bin/env bash
# blocking SSM port-forward localhost:8000 -> ECS container instance:8000 (hostPort)
set -euo pipefail
cd "$(dirname "$0")"
region=${AWS_REGION:-us-east-1}
id=$(aws autoscaling describe-auto-scaling-groups --region "$region" \
  --auto-scaling-group-names "$(terraform output -raw asg_name)" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
exec aws ssm start-session --region "$region" --target "$id" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8000"],"localPortNumber":["'${LOCAL_PORT:-8000}'"]}'
