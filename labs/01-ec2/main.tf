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
  default_tags { tags = { lab = "01-ec2" } }
}

# only AZs that actually offer the GPU type
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
  tags                 = { Name = "lab-ec2" }
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
  name = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id"
}

resource "aws_iam_role" "this" {
  name_prefix = "lab-ec2-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "lab-ec2-"
  role        = aws_iam_role.this.name
}

# no ingress: access is SSM port-forward only
resource "aws_security_group" "this" {
  name_prefix = "lab-ec2-"
  vpc_id      = aws_vpc.this.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "vllm" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.this.id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = true # egress to HF + SSM without NAT

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  # T4 has no bf16 -> --dtype half
  user_data = <<-EOT
    #!/bin/bash
    docker run -d --restart always --gpus all --ipc=host -p 8000:8000 \
      -e VLLM_USE_FLASHINFER_SAMPLER=0 \
      ${var.vllm_image} --model ${var.model} --dtype half --max-model-len 2048
  EOT

  tags = { Name = "lab-ec2-vllm" }
}

output "instance_id" { value = aws_instance.vllm.id }
