variable "aws_region" {
  description = "AWS region where the VPC will be deployed"
  type        = string
  default     = "us-east-1"
  validation {
    condition     = can(regex("^([a-z]{2}-[a-z]+-[0-9]{1})$", var.aws_region))
    error_message = "Invalid AWS region format. Please provide a valid region in the format 'us-west-2'."
  }
}

variable "project_name" {
  type        = string
  description = "Name of the project"
  default     = "my-projec-1"
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Invalid project name. Please provide a valid name using lowercase letters and hyphens (-)."
  }
}

variable "environment" {
  type        = string
  description = "Deployment Environment"
  default     = "sandbox"
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "Invalid environment name. Please provide a valid name using lowercase letters and hyphens (-)."
  }
}

variable "vpc_cidr_block" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
  validation {
    condition     = length(var.vpc_cidr_block) > 0 && can(regex("^\\d+\\.\\d+\\.\\d+\\.\\d+/\\d+$", var.vpc_cidr_block))
    error_message = "Invalid VPC CIDR block"
  }
}

variable "public_subnet_mask_bits" {
  type        = number
  description = "Number of bits for subnet mask"
  default     = 10 # Example: /16 + 10 = /26
  validation {
    condition     = var.public_subnet_mask_bits >= 1 && var.public_subnet_mask_bits <= 14
    error_message = "Subnet mask bits must be between 1 and 14"
  }
}

variable "subnet_layers" {
  description = "Map of subnet layers to their corresponding newbits to extend the VPC CIDR block"
  type        = map(number)
  default = {
    app      = 7  # Example: /16 + 7 = /23
    dmz      = 12 # Example: /16 + 12 = /28
    database = 12 # Example: /16 + 10 = /28
  }
}

variable "az_count" {
  type        = number
  description = "Number of availability zones"
  default     = 2
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "Availability zone count must be between 2 and 3"
  }
}

variable "use_nat_gateway" {
  type        = bool
  description = "Flag to enable/disable NAT Gateways"
  default     = true
}

variable "nat_gateway_count" {
  type        = number
  description = "Number of NAT Gateways"
  default     = 1
  validation {
    condition     = var.nat_gateway_count >= 1 && var.nat_gateway_count <= 3
    error_message = "NAT Gateway count must be between 1 and availability zone count"
  }
}

variable "use_transit_gateway" {
  type        = bool
  description = "Flag to enable/disable Transit Gateway"
  default     = false
}

variable "transit_gateway_id" {
  type        = string
  description = "ID of the Transit Gateway"
  default     = "tgw-1234567890abcdef1"
  validation {
    condition     = can(regex("^tgw-[0-9a-f]{17}$", var.transit_gateway_id)) || length(var.transit_gateway_id) == null
    error_message = "Transit Gateway ID is required when using Transit Gateway"
  }
}

variable "s3_vpc_endpoint_enabled" {
  type        = bool
  description = "Flag to enable/disable S3 VPC Endpoint"
  default     = true
}

variable "dynamodb_vpc_endpoint_enabled" {
  type        = bool
  description = "Flag to enable/disable DynamoDB VPC Endpoint"
  default     = true
}

variable "ec2_vpc_endpoint_enabled" {
  type        = bool
  description = "Flag to enable/disable EC2 VPC Endpoint"
  default     = true
}

variable "ssm_vpc_endpoint_enabled" {
  type        = bool
  description = "Flag to enable/disable SSM VPC Endpoint"
  default     = false
}

variable "ssmmessages_vpc_endpoint_enabled" {
  type        = bool
  description = "Flag to enable/disable SSM Messages VPC Endpoint"
  default     = false
}

variable "additional_cidrs" {
  type        = string
  description = "Additional CIDR blocks for routing (comma-separated)"
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to AWS resources"
  default = {
    owner = "Frankin Garcia"
  }
}
