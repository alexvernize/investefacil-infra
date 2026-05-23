variable "aws_region" {
  description = "Região AWS onde os recursos serão provisionados."
  type        = string
  default     = "sa-east-1"
}

variable "environment" {
  description = "Nome do ambiente (dev, staging, prod)."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment deve ser 'dev', 'staging' ou 'prod'."
  }
}

variable "project" {
  description = "Nome do projeto — usado como prefixo em todos os recursos."
  type        = string
  default     = "investefacil"
}

# ── Rede ────────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "Bloco CIDR da VPC principal."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs das subnets públicas (uma por AZ — para ALB/NAT Gateway)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs das subnets privadas (uma por AZ — onde rodam as aplicações)."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "availability_zones" {
  description = "Lista de AZs a usar. Deve ter o mesmo tamanho que as listas de subnets."
  type        = list(string)
  default     = ["sa-east-1a", "sa-east-1b"]
}
