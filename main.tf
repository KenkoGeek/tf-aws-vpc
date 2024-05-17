# terraform {
#   backend "s3" {
#     bucket = "my-terraform-state-bucket"
#     key    = "my-terraform-state-key"
#     region = var.aws_region
#     # dynamodb_table = "my-terraform-state-lock"
#   }
# }

locals {
  az_suffixes = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  environment_map = {
    development = "dev"
    test        = "test"
    production  = "prod"
    staging     = "stg"
    sandbox     = "sandbox"
  }
}

# Create VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = merge(var.tags, {
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-vpc"
    environment = var.environment
  })
}

# Create Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = merge(var.tags, {
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-igw"
    environment = var.environment
  })
}

# Create subnets
resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr_block, var.public_subnet_mask_bits, count.index)
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-public-${substr(element(local.az_suffixes, count.index), -2, 2)}"
    environment = var.environment
  })
}

# Create public route table and associate with public subnet
resource "aws_route_table_association" "public_subnet_association" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "public" {
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.vpc_attachment]
  count      = var.use_transit_gateway ? 1 : var.nat_gateway_count

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
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-public-route-table"
    environment = var.environment
  })
}

resource "aws_subnet" "private" {
  count = var.az_count * length(var.subnet_layers)


  cidr_block = count.index == 0 ? cidrsubnet(aws_vpc.main.cidr_block, lookup(
    var.subnet_layers,
    element(keys(var.subnet_layers), floor(count.index / var.az_count)),
    8
    ), var.az_count + count.index * length(var.subnet_layers)) : count.index > 0 ? cidrsubnet(aws_vpc.main.cidr_block, lookup(
    var.subnet_layers,
    element(keys(var.subnet_layers), floor(count.index / var.az_count)),
    8
  ), count.index + var.az_count) : null

  vpc_id            = aws_vpc.main.id
  availability_zone = element(data.aws_availability_zones.available.names, count.index % var.az_count)

  tags = merge(var.tags, {
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-private-${element(keys(var.subnet_layers), floor(count.index / var.az_count))}-${substr(element(local.az_suffixes, count.index % var.az_count), -2, 2)}"
    environment = var.environment
  })
  depends_on = [aws_subnet.public]
}

resource "aws_ec2_transit_gateway_vpc_attachment" "vpc_attachment" {
  depends_on         = [aws_vpc.main]
  count              = var.use_transit_gateway ? 1 : 0
  subnet_ids         = [for az in range(var.az_count) : aws_subnet.private[az].id]
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
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-nat-gateway-${substr(element(local.az_suffixes, count.index), -2, 2)}"
    environment = var.environment
  })
}

resource "aws_eip" "nat_eip" {
  count = var.use_transit_gateway == false && var.use_nat_gateway ? var.nat_gateway_count : 0

  tags = merge(var.tags, {
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-nat-eip-${count.index}"
    environment = var.environment
  })
}

# Create private route table and associate with private subnets
resource "aws_route_table" "private" {
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.vpc_attachment]
  count      = var.use_transit_gateway ? 1 : var.nat_gateway_count

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
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-private-route-table"
    environment = var.environment
  })
}

resource "aws_route_table_association" "private_subnet_association" {
  count          = var.az_count * length(var.subnet_layers)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[var.nat_gateway_count == 1 ? 0 : count.index % var.nat_gateway_count].id
}

# Create security group VPC Endpoint
resource "aws_security_group" "vpc_endpoint_sg" {
  name        = "${var.project_name}-${local.environment_map[var.environment]}-vpc-endpoint-sg"
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
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-vpc-endpoint-sg"
    environment = var.environment
  })
}


# Create S3 VPC Endpoint (if enabled)
resource "aws_vpc_endpoint" "s3_vpc_endpoint" {
  count        = var.s3_vpc_endpoint_enabled ? 1 : 0
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.aws_region}.s3"
  tags = merge(var.tags, {
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-s3-vpc-endpoint"
    environment = var.environment
  })
}

# Create DynamoDB VPC Endpoint (if enabled)
resource "aws_vpc_endpoint" "dynamodb_vpc_endpoint" {
  count        = var.dynamodb_vpc_endpoint_enabled ? 1 : 0
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.aws_region}.dynamodb"
  tags = merge(var.tags, {
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-dynamodb-vpc-endpoint"
    environment = var.environment
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
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-ec2-vpc-endpoint"
    environment = var.environment
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
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-ssm-vpc-endpoint"
    environment = var.environment
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
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-ssmmessages-vpc-endpoint"
    environment = var.environment
  })
}

# Create KMS CMK for Flow Logs encryption
resource "aws_kms_key" "flowlogs_kms_key" {
  description             = "KMS CMK for Flow Logs encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(var.tags, {
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-flowlogs-kms-key"
    environment = var.environment
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

resource "aws_kms_alias" "key_alias" {
  name          = "alias/${var.project_name}-${var.environment}-flowlogs-key"
  target_key_id = aws_kms_key.flowlogs_kms_key.key_id
}

# Create CloudWatch Logs group for Flow Logs
resource "aws_cloudwatch_log_group" "flowlogs_log_group" {
  name              = "/vpc/${var.project_name}/flowlogs"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.flowlogs_kms_key.arn

  tags = merge(var.tags, {
    Name        = "${var.project_name}-${local.environment_map[var.environment]}-flowlogs-log-group"
    environment = var.environment
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
  name               = "${var.project_name}-${local.environment_map[var.environment]}-flowlogs-role"
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
    Name        = "${var.project_name}-flowlogs-role"
    environment = var.environment
  })
}
