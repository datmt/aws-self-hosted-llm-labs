terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

variable "region" { default = "us-east-1" }
variable "instance_type" { default = "g4dn.xlarge" }
variable "model" { default = "Qwen/Qwen2.5-0.5B-Instruct" }
variable "vllm_image" { default = "vllm/vllm-openai:v0.10.2" }

provider "aws" {
  region = var.region
  default_tags { tags = { lab = "02-ecs-ec2" } }
}

data "aws_ec2_instance_type_offerings" "gpu" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

# own VPC: the account's default VPC has a deleted IGW (blackhole route) so it has no internet
resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/24"
  enable_dns_hostnames = true
  tags                 = { Name = "lab-ecs-ec2" }
}

resource "aws_internet_gateway" "this" { vpc_id = aws_vpc.this.id }

resource "aws_subnet" "this" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.0.0/25"
  availability_zone       = sort(data.aws_ec2_instance_type_offerings.gpu.locations)[0]
  map_public_ip_on_launch = true
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.this.id
}

data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/gpu/recommended/image_id"
}

locals {
  assume = { for svc in ["ec2", "ecs-tasks"] : svc => jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "${svc}.amazonaws.com" } }]
  }) }
}

# --- container instance role (ECS agent + SSM for port-forward)
resource "aws_iam_role" "instance" {
  name_prefix        = "lab-ecs-inst-"
  assume_role_policy = local.assume["ec2"]
}

resource "aws_iam_role_policy_attachment" "instance" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.instance.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "instance" {
  name_prefix = "lab-ecs-"
  role        = aws_iam_role.instance.name
}

# --- task execution role (log delivery)
resource "aws_iam_role" "exec" {
  name_prefix        = "lab-ecs-exec-"
  assume_role_policy = local.assume["ecs-tasks"]
}

resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "this" {
  name_prefix       = "/lab/ecs-vllm-"
  retention_in_days = 1
}

# --- cluster + 1 GPU instance via ASG capacity provider
resource "aws_ecs_cluster" "this" { name = "lab-vllm" }

resource "aws_security_group" "this" {
  name_prefix = "lab-ecs-"
  vpc_id      = aws_vpc.this.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_template" "this" {
  # keep the role's policies until the instance is gone, else the ECS agent loses
  # permissions mid-destroy, can't report tasks stopped, and the service hangs in DRAINING
  depends_on             = [aws_iam_role_policy_attachment.instance]
  name_prefix            = "lab-ecs-"
  image_id               = data.aws_ssm_parameter.ami.value
  instance_type          = var.instance_type
  user_data              = base64encode("#!/bin/bash\necho ECS_CLUSTER=${aws_ecs_cluster.this.name} >> /etc/ecs/ecs.config\n")

  iam_instance_profile { name = aws_iam_instance_profile.instance.name }

  network_interfaces {
    associate_public_ip_address = true # egress to HF + Docker Hub without NAT
    security_groups             = [aws_security_group.this.id]
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 100
      volume_type = "gp3"
    }
  }
}

resource "aws_autoscaling_group" "this" {
  name_prefix         = "lab-ecs-"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.this.id]
  force_delete        = true

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  tag {
    key                 = "lab"
    value               = "02-ecs-ec2"
    propagate_at_launch = true
  }
}

resource "aws_ecs_capacity_provider" "this" {
  name = "lab-vllm-gpu"
  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.this.arn
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = [aws_ecs_capacity_provider.this.name]
}

# --- vLLM task: bridge net, hostPort 8000, 1 GPU
resource "aws_ecs_task_definition" "this" {
  family                   = "lab-vllm"
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
  execution_role_arn       = aws_iam_role.exec.arn
  cpu                      = 3072
  memory                   = 12288

  container_definitions = jsonencode([{
    name         = "vllm"
    image        = var.vllm_image
    essential    = true
    command      = ["--model", var.model, "--dtype", "half", "--max-model-len", "2048"]
    # T4: FlashInfer top-p sampler kernel fails ("too many resources requested for launch")
    environment  = [{ name = "VLLM_USE_FLASHINFER_SAMPLER", value = "0" }]
    portMappings = [{ containerPort = 8000, hostPort = 8000 }]
    resourceRequirements = [{ type = "GPU", value = "1" }]
    linuxParameters      = { sharedMemorySize = 2048 }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "vllm"
      }
    }
  }])
}

resource "aws_ecs_service" "this" {
  name            = "vllm"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 1
  force_delete    = true

  # single GPU host: stop old task before starting new (hostPort + GPU are exclusive)
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  availability_zone_rebalancing      = "DISABLED"

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.this.name
    weight            = 1
  }

  depends_on = [aws_ecs_cluster_capacity_providers.this, aws_iam_role_policy_attachment.exec]
}

output "asg_name" { value = aws_autoscaling_group.this.name }
output "log_group" { value = aws_cloudwatch_log_group.this.name }
