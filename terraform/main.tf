# ── VPC ──────────────────────────────────────────────────────────────────────
# Rede isolada principal. DNS habilitado para resolução de nomes de serviços
# AWS internos (RDS, ECR, Secrets Manager via VPC Endpoint).
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-${var.environment}-vpc" }
}

# ── Subnets Públicas ─────────────────────────────────────────────────────────
# Usadas para: Application Load Balancer e NAT Gateway.
# Nunca colocar instâncias de aplicação aqui — apenas recursos que precisam de
# IP público (load balancers, bastion hosts temporários).
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-${var.environment}-public-${count.index + 1}" }
}

# ── Subnets Privadas ─────────────────────────────────────────────────────────
# Onde rodam as aplicações (ECS Fargate tasks). Sem IP público direto.
# Saída para internet via NAT Gateway na subnet pública.
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${var.project}-${var.environment}-private-${count.index + 1}" }
}

# ── Internet Gateway ──────────────────────────────────────────────────────────
# Porta de entrada/saída para tráfego público (ALB → internet).
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-${var.environment}-igw" }
}

# ── Elastic IP para o NAT Gateway ────────────────────────────────────────────
# IP fixo do NAT — permite allowlisting deste IP em serviços externos
# (ex.: whitelist do IP na API do BCB em produção).
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.project}-${var.environment}-nat-eip" }
}

# ── NAT Gateway ──────────────────────────────────────────────────────────────
# Uma única instância na primeira subnet pública (custo vs. disponibilidade).
# Para produção com HA, criar um NAT por AZ.
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.main]

  tags = { Name = "${var.project}-${var.environment}-nat" }
}

# ── Tabela de Rotas Pública ───────────────────────────────────────────────────
# Todo o tráfego de saída das subnets públicas vai direto para o IGW.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-${var.environment}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Tabela de Rotas Privada ───────────────────────────────────────────────────
# Tráfego de saída das subnets privadas vai pelo NAT (sem IP público direto).
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project}-${var.environment}-rt-private" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Security Group Base — Backend ─────────────────────────────────────────────
# Permite entrada apenas do ALB (porta 8080) e bloqueia todo o resto.
# Será referenciado pelo módulo de compute quando o ECS for adicionado.
resource "aws_security_group" "backend" {
  name        = "${var.project}-${var.environment}-sg-backend"
  description = "Trafego permitido para o container do backend Go"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP do ALB para o backend"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Saida irrestrita (BCB API, ECR, Secrets Manager)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-${var.environment}-sg-backend" }
}

# ── Security Group Base — ALB ─────────────────────────────────────────────────
# Application Load Balancer aceita HTTPS da internet e HTTP para redirecionamento.
resource "aws_security_group" "alb" {
  name        = "${var.project}-${var.environment}-sg-alb"
  description = "Trafego permitido para o Application Load Balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS publico"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP para redirect 301 para HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Repasse para os containers nas subnets privadas"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-${var.environment}-sg-alb" }
}
