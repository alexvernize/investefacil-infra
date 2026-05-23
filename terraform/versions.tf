terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }

  # State remoto — bucket e tabela criados pelo script scripts/bootstrap.sh
  # antes do primeiro `terraform init`.
  backend "s3" {
    bucket         = "investefacil-terraform-state"
    key            = "infra/terraform.tfstate"
    region         = "sa-east-1"
    encrypt        = true
    dynamodb_table = "investefacil-tf-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "investefacil"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
