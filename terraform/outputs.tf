output "vpc_id" {
  description = "ID da VPC principal."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs das subnets públicas (para ALB)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas (para ECS tasks)."
  value       = aws_subnet.private[*].id
}

output "nat_gateway_public_ip" {
  description = "IP público fixo do NAT Gateway — fazer allowlist na API do BCB em produção."
  value       = aws_eip.nat.public_ip
}

output "sg_backend_id" {
  description = "ID do Security Group do backend — referenciar no módulo ECS."
  value       = aws_security_group.backend.id
}

output "sg_alb_id" {
  description = "ID do Security Group do ALB."
  value       = aws_security_group.alb.id
}
