#!/usr/bin/env bash
# bootstrap.sh — cria os pré-requisitos do backend remoto do Terraform.
# Execute UMA VEZ antes do primeiro `terraform init`.
# Requer: AWS CLI configurado com permissões de administrador.

set -euo pipefail

REGION="sa-east-1"
BUCKET="investefacil-terraform-state"
TABLE="investefacil-tf-lock"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo ">>> Conta AWS: ${ACCOUNT_ID} | Região: ${REGION}"

# ── S3 Bucket para o state ───────────────────────────────────────────────────
echo ">>> Criando bucket S3: ${BUCKET}"
aws s3api create-bucket \
  --bucket "${BUCKET}" \
  --region "${REGION}" \
  --create-bucket-configuration LocationConstraint="${REGION}"

# Versioning — permite recuperar states anteriores em caso de falha no apply.
aws s3api put-bucket-versioning \
  --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled

# Criptografia AES-256 em repouso.
aws s3api put-bucket-encryption \
  --bucket "${BUCKET}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}
    }]
  }'

# Bloqueia acesso público ao bucket de state.
aws s3api put-public-access-block \
  --bucket "${BUCKET}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo ">>> Bucket ${BUCKET} criado e configurado."

# ── DynamoDB para locking ────────────────────────────────────────────────────
echo ">>> Criando tabela DynamoDB: ${TABLE}"
aws dynamodb create-table \
  --table-name "${TABLE}" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "${REGION}"

echo ">>> Tabela ${TABLE} criada."

echo ""
echo "Bootstrap concluído. Execute agora:"
echo "  cd terraform && terraform init"
