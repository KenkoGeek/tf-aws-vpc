output "vpc_cidr_block" {
  value       = aws_vpc.main.cidr_block
  description = "VPC CIDR"
}

output "vpc_id" {
  value       = aws_vpc.main.id
  description = "VPC ID"
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "Public subnets IDs"
}

output "public_subnet_cidrs" {
  value       = aws_subnet.public[*].cidr_block
  description = "Public subnets CIDRs"
}

output "private_subnet_ids" {
  value = flatten([
    for i in range(local.app_layers) : [
      for j in range(var.az_count) : {
        layer_name = element(var.layer_names, i)
        subnet_id  = aws_subnet.private[i * var.az_count + j].id
      }
    ]
  ])
  description = "Private subnets IDs by layer"
}

output "private_subnets_cidr" {
  value = flatten([
    for i in range(local.app_layers) : [
      for j in range(var.az_count) : {
        layer_name = element(var.layer_names, i)
        cidr       = aws_subnet.private[i * var.az_count + j].cidr_block
      }
    ]
  ])
  description = "Private subnets CIDRs by layer"
}