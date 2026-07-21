########################################
# AMI: latest Amazon Linux 2023 (x86_64)
########################################
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

########################################
# Networking: default VPC / subnet lookup
########################################
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  subnet_id = var.subnet_id != "" ? var.subnet_id : data.aws_subnets.default.ids[0]
}

########################################
# Security group: egress only (no ingress)
# SSM reaches its endpoints over outbound 443; no inbound SSH is opened.
########################################
resource "aws_security_group" "egress_only" {
  name_prefix = "${var.name}-egress-"
  description = "Egress-only SG for SSM-managed instance (no inbound access)."
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "HTTPS out to AWS SSM endpoints and package mirrors."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-egress"
  }

  lifecycle {
    create_before_destroy = true
  }
}

########################################
# IAM: instance role for SSM Session Manager
########################################
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm" {
  name_prefix        = "${var.name}-ssm-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Name = "${var.name}-ssm"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name_prefix = "${var.name}-ssm-"
  role        = aws_iam_role.ssm.name
}

########################################
# EC2 instance (hardened)
########################################
resource "aws_instance" "linux" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.egress_only.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  associate_public_ip_address = true # egress-only path to SSM; no inbound is open

  # IMDSv2 required (blocks SSRF-style metadata theft).
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  # Encrypted root volume.
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
  }

  tags = {
    Name = var.name
  }
}
