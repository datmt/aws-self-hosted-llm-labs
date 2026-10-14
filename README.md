# aws-self-hosted-llm-labs

Terraform labs that stand up a **tiny LLM on a single GPU** in AWS, hit it with the same
OpenAI-compatible API calls, capture timings and server evidence, then **tear everything down**.

Same model, same runtime, same tests, different AWS compute. The point is to compare the operational
shape of each option, not to benchmark a big model.

| Lab | Compute | Resources |
|---|---|---|
| [`labs/01-ec2`](labs/01-ec2) | One `g4dn.xlarge`, `docker run` from `user_data` | 5 |
| [`labs/02-ecs-ec2`](labs/02-ecs-ec2) | ECS cluster, ASG capacity provider, GPU task + service | 15 |

Fargate has no GPU support, so it is not included. SageMaker HyperPod was scoped out: it is
training-oriented and `ml.*` GPU cluster quota is 0 on new accounts.

**Findings and numbers are in [REPORT.md](REPORT.md).** Short version: both serve the model with
identical steady-state latency (~0.47 s for a short completion on a T4). They differ in operations, and
cold start is dominated by pulling the ~20 GB vLLM image.

## What it runs

- Model: `Qwen/Qwen2.5-0.5B-Instruct` (pulled from Hugging Face at start)
- Runtime: `vllm/vllm-openai:v0.10.2`, `--dtype half --max-model-len 2048`
- Instance: `g4dn.xlarge` (1x T4), on-demand, `us-east-1`
- Access: SSM port-forward only. No ingress rules, no load balancer, no public endpoint
- Each lab creates its own small VPC with an internet gateway and one public subnet

## Prerequisites

- Terraform >= 1.5, AWS CLI v2, [`session-manager-plugin`](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html), `curl`, `bash`
- AWS credentials with permission to create EC2, VPC, IAM, ECS, Auto Scaling and CloudWatch Logs resources
- Service quota **"Running On-Demand G and VT instances" >= 4 vCPU** (8 to run both labs at once). New accounts often start at 0

## Usage

```bash
export AWS_PROFILE=<profile> AWS_REGION=us-east-1

make e2e LAB=01-ec2        # apply -> wait healthy -> smoke x3 -> capture -> destroy (always) -> leftovers
make e2e LAB=02-ecs-ec2

# both at once: give the second a different local tunnel port
PORT=8001 make e2e LAB=02-ecs-ec2
```

Or step by step:

```bash
make up   LAB=01-ec2       # terraform init + apply
make test LAB=01-ec2       # opens tunnel, waits for /health, runs tests/smoke.sh
make down LAB=01-ec2       # terraform destroy
make leftovers             # list anything still tagged lab=* (tag index lags a few minutes)
```

`make e2e` writes `runs/<lab>/<timestamp>/` with `timeline.txt`, `apply.log`, `smoke.log`,
`server.log` (nvidia-smi + container log), `destroy.log` and `leftovers.txt`. `runs/` is gitignored
because it contains account and instance IDs.

## Layout

```
Makefile              up | test | down | e2e | leftovers
tests/smoke.sh        /health, /v1/models, one chat call; prints latency and tok/s
tests/run.sh          open tunnel, wait for health, run smoke.sh
tests/e2e.sh          full lifecycle with capture; destroy runs in a trap
labs/<lab>/main.tf    the infrastructure
labs/<lab>/tunnel.sh  blocking SSM port-forward to localhost:${LOCAL_PORT:-8000}
```

## Cost and time

- About **$0.53/h** per running lab (`g4dn.xlarge` on-demand, `us-east-1`)
- Expect **15-20 min** to ready (image pull) and 7-20 min to destroy. Budget about $0.30 per clean run
- Always confirm teardown with `make leftovers` and your own console. A forgotten GPU instance bills until terminated

## Known sharp edges

- **T4 + vLLM 0.10.2:** the FlashInfer top-p sampler fails on compute capability 7.5. The labs set `VLLM_USE_FLASHINFER_SAMPLER=0`
- **Default VPC:** some accounts have a default VPC whose route table points at a deleted IGW. That is why the labs build their own
- **ECS destroy:** the instance role's policies must outlive the ECS agent, otherwise the service hangs in `DRAINING`. The config orders this with `depends_on`
- **Image pull:** pre-bake an AMI or mirror the image to ECR to cut cold start

Details and the full issue log are in [REPORT.md](REPORT.md).

## Not production

No TLS, auth, autoscaling, load balancer or health-based replacement. Local Terraform state. Treat this as a
lab harness.
