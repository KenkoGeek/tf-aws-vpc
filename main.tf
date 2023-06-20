# terraform {
#   backend "s3" {
#     bucket = "my-terraform-state-bucket"
#     key    = "my-terraform-state-key"
#     region = var.aws_region
#     # dynamodb_table = "my-terraform-state-lock"
#   }
# }

# Create VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = merge(var.tags, {
    Name = "${var.project_name}-vpc"
  })
}

# Create Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = merge(var.tags, {
    Name = "${var.project_name}-igw"
  })
}

locals {
  az_suffixes = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# Create subnets
resource "aws_subnet" "public" {
  count             = var.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr_block, var.subnet_mask_bits, count.index * 2)
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-${substr(element(local.az_suffixes, count.index), -2, 2)}"
  })
}

# Create public route table and associate with public subnet
resource "aws_route_table_association" "public_subnet_association" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "public" {
  count = var.use_transit_gateway ? 1 : var.nat_gateway_count

  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  dynamic "route" {
    for_each = var.additional_cidrs != "" ? split(",", var.additional_cidrs) : []
    content {
      cidr_block = route.value
      gateway_id = var.use_transit_gateway ? var.transit_gateway_id : aws_nat_gateway.nat_gateway[count.index].id
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-route-table"
  })
}

resource "aws_subnet" "private" {
  count             = var.az_count * var.app_layers
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr_block, var.subnet_mask_bits, (count.index * 2) + 1)
  availability_zone = element(data.aws_availability_zones.available.names, count.index % var.az_count)

  tags = merge(var.tags, {
    Name = "${var.project_name}-private-${element(var.layer_names, count.index % var.app_layers)}-${substr(element(local.az_suffixes, count.index % var.az_count), -2, 2)}"
  })
  depends_on = [aws_subnet.public]
}

resource "aws_ec2_transit_gateway_vpc_attachment" "vpc_attachment" {
  count              = var.use_transit_gateway ? 1 : 0
  subnet_ids         = [aws_subnet.private[0].id, aws_subnet.private[1].id]
  transit_gateway_id = var.transit_gateway_id
  vpc_id             = aws_vpc.main.id
}

# Create NAT Gateways for private subnet outbount traffic
resource "aws_nat_gateway" "nat_gateway" {
  count = var.use_transit_gateway == false && var.use_nat_gateway ? var.nat_gateway_count : 0

  allocation_id = aws_eip.nat_eip[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  depends_on = [
    aws_internet_gateway.igw,
    aws_subnet.public
  ]
  tags = merge(var.tags, {
    Name = "${var.project_name}-nat-gateway-${substr(element(local.az_suffixes, count.index), -2, 2)}"
  })
}

resource "aws_eip" "nat_eip" {
  count = var.use_transit_gateway == false && var.use_nat_gateway ? var.nat_gateway_count : 0

  tags = merge(var.tags, {
    Name = "${var.project_name}-nat-eip-${count.index}"
  })
}

# Create private route table and associate with private subnets
resource "aws_route_table" "private" {
  count = var.use_transit_gateway ? 1 : var.nat_gateway_count

  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = var.use_transit_gateway ? [1] : [var.nat_gateway_count]
    content {
      cidr_block = "0.0.0.0/0"
      gateway_id = var.use_transit_gateway ? var.transit_gateway_id : aws_nat_gateway.nat_gateway[count.index].id
    }
  }

  dynamic "route" {
    for_each = var.additional_cidrs != "" ? split(",", var.additional_cidrs) : []
    content {
      cidr_block = route.value
      gateway_id = var.use_transit_gateway ? var.transit_gateway_id : aws_nat_gateway.nat_gateway[count.index].id
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-private-route-table"
  })
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.vpc_attachment]
}

resource "aws_route_table_association" "private_subnet_association" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

# Create security group VPC Endpoint
resource "aws_security_group" "vpc_endpoint_sg" {
  name        = "${var.project_name}-vpc-endpoint-sg"
  description = "Security group for VPC endpoints"

  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
    description = "Allow 443 from local VPC"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
    description = "Allow outbound traffic 443 to local VPC"
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-vpc-endpoint-sg"
  })
}


# Create S3 VPC Endpoint (if enabled)
resource "aws_vpc_endpoint" "s3_vpc_endpoint" {
  count        = var.s3_vpc_endpoint_enabled ? 1 : 0
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.aws_region}.s3"
  tags = merge(var.tags, {
    Name = "${var.project_name}-s3-vpc-endpoint"
  })
}

# Create DynamoDB VPC Endpoint (if enabled)
resource "aws_vpc_endpoint" "dynamodb_vpc_endpoint" {
  count        = var.dynamodb_vpc_endpoint_enabled ? 1 : 0
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.aws_region}.dynamodb"
  tags = merge(var.tags, {
    Name = "${var.project_name}-dynamodb-vpc-endpoint"
  })
}

# Create EC2 VPC Endpoint (if enabled)
resource "aws_vpc_endpoint" "ec2_vpc_endpoint" {
  count               = var.ec2_vpc_endpoint_enabled ? 1 : 0
  vpc_id              = aws_vpc.main.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  service_name        = "com.amazonaws.${var.aws_region}.ec2"
  security_group_ids = [
    aws_security_group.vpc_endpoint_sg.id
  ]
  tags = merge(var.tags, {
    Name = "${var.project_name}-ec2-vpc-endpoint"
  })
}

# Create SSM VPC Endpoint (if enabled)
resource "aws_vpc_endpoint" "ssm_vpc_endpoint" {
  count               = var.ssm_vpc_endpoint_enabled ? 1 : 0
  vpc_id              = aws_vpc.main.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  security_group_ids = [
    aws_security_group.vpc_endpoint_sg.id
  ]
  tags = merge(var.tags, {
    Name = "${var.project_name}-ssm-vpc-endpoint"
  })
}

# Create SSM Messages VPC Endpoint (if enabled)
resource "aws_vpc_endpoint" "ssmmessages_vpc_endpoint" {
  count               = var.ssmmessages_vpc_endpoint_enabled ? 1 : 0
  vpc_id              = aws_vpc.main.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  security_group_ids = [
    aws_security_group.vpc_endpoint_sg.id
  ]
  tags = merge(var.tags, {
    Name = "${var.project_name}-ssmmessages-vpc-endpoint"
  })
}

# Create KMS CMK for Flow Logs encryption
resource "aws_kms_key" "flowlogs_kms_key" {
  description             = "KMS CMK for Flow Logs encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-flowlogs-kms-key"
  })
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Id": "key-policy",
  "Statement": [
    {
      "Sid": "AllowAdminToLocalAccount",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      },
      "Action": [
        "kms:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowUseForCloudWatchLogs",
      "Effect": "Allow",
      "Principal": {
        "Service": "logs.${var.aws_region}.amazonaws.com"
      },
      "Action": [
        "kms:Encrypt*",
        "kms:Decrypt*",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*"
    ],
      "Resource": "*"
    }
  ]
}
EOF
}

# Create CloudWatch Logs group for Flow Logs
resource "aws_cloudwatch_log_group" "flowlogs_log_group" {
  name              = "/vpc/${var.project_name}/flowlogs"
  retention_in_days = 90
  kms_key_id        = aws_kms_key.flowlogs_kms_key.arn

  tags = merge(var.tags, {
    Name = "${var.project_name}-flowlogs-log-group"
  })
}

# Create Flow Logs
resource "aws_flow_log" "flowlogs" {
  depends_on           = [aws_cloudwatch_log_group.flowlogs_log_group]
  log_destination      = aws_cloudwatch_log_group.flowlogs_log_group.arn
  log_destination_type = "cloud-watch-logs"
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.main.id
  iam_role_arn         = aws_iam_role.flowlogs_role.arn
}

# Create IAM Role for Flow Logs
resource "aws_iam_role" "flowlogs_role" {
  name               = "${var.project_name}-flowlogs-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "vpc-flow-logs.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  tags = merge(var.tags, {
    Name = "${var.project_name}-flowlogs-role"
  })
}
