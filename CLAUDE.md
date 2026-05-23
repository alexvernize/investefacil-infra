# investefacil-infra — Guia de Engenharia de Infraestrutura

## O que é este repositório

Fonte única da verdade para toda a infraestrutura do ecossistema investefacil.
Orquestra os serviços localmente via Docker Compose e provisiona a infraestrutura
em nuvem (AWS sa-east-1) via Terraform.

**Repositórios relacionados:**
- `../investefacil` — Backend Go (API)
- `../investefacil-front` — Frontend Next.js

---

## Estrutura de diretórios

```
investefacil-infra/
├── docker-compose.yml         ← orquestração local (builds apontam para repos irmãos)
├── .env.example               ← template de variáveis — copiar para .env
├── .gitignore
├── CLAUDE.md
├── terraform/
│   ├── versions.tf            ← provider AWS + backend S3/DynamoDB
│   ├── variables.tf           ← todas as variáveis com validação
│   ├── main.tf                ← VPC, subnets, IGW, NAT, security groups
│   └── outputs.tf             ← IDs e IPs exportados para outros módulos
├── scripts/
│   └── bootstrap.sh           ← cria S3 bucket + DynamoDB (rodar UMA VEZ)
└── .github/
    └── workflows/
        ├── tf-plan.yml        ← valida e posta plano em PRs
        └── tf-apply.yml       ← aplica em merge para main (requer aprovação)
```

---

## Pré-requisitos

| Ferramenta | Versão mínima | Instalação |
|---|---|---|
| Docker Desktop | 4.x | https://docs.docker.com/desktop/ |
| Terraform | 1.9.x | `brew install terraform` |
| tflint | latest | `brew install tflint` |
| AWS CLI | 2.x | `brew install awscli` |

---

## Desenvolvimento local com Docker Compose

### Primeiro uso
```bash
# 1. Copiar e preencher variáveis de ambiente
cp .env.example .env

# 2. Subir todo o ecossistema (faz build local das imagens)
docker compose up --build

# 3. Verificar saúde dos serviços
docker compose ps
```

### Operações do dia a dia
```bash
# Subir em background
docker compose up -d

# Ver logs em tempo real
docker compose logs -f

# Ver logs de um serviço específico
docker compose logs -f backend
docker compose logs -f frontend

# Rebuild de um único serviço (após mudança no código)
docker compose up -d --build backend

# Parar tudo (preserva volumes)
docker compose down

# Parar e remover volumes (reset completo)
docker compose down -v
```

### Endpoints locais
| Serviço | URL |
|---|---|
| Backend API | http://localhost:8080 |
| Health check | http://localhost:8080/healthz |
| Frontend | http://localhost:3000 |

---

## Terraform — Provisionamento AWS

### Bootstrap (rodar UMA VEZ por conta AWS)
Cria o bucket S3 e a tabela DynamoDB que armazenam o state remoto.
Requer AWS CLI autenticado com permissões de administrador.

```bash
./scripts/bootstrap.sh
```

### Ciclo normal

```bash
cd terraform

# Inicializar — baixa providers e conecta ao backend S3
terraform init

# Validar sintaxe e tipos
terraform validate

# Lint com regras de boas práticas
tflint --init && tflint

# Planejar mudanças (dev)
terraform plan -var="environment=dev"

# Planejar para produção
terraform plan -var="environment=prod"

# Aplicar (nunca rodar -auto-approve localmente em prod)
terraform apply -var="environment=dev"

# Destruir ambiente de dev (cuidado — irreversível)
terraform destroy -var="environment=dev"
```

### Formatação e validação pré-commit
```bash
# Formata todos os arquivos .tf
terraform fmt -recursive

# Valida
terraform validate
```

---

## Variáveis de ambiente obrigatórias

### Para Docker Compose (arquivo `.env`)

| Variável | Obrigatória | Descrição |
|---|---|---|
| `PORT` | Não (default 8080) | Porta do backend |
| `ALLOWED_ORIGIN` | Sim em produção | Origem CORS do frontend |

### Para Terraform (via `TF_VAR_*` ou `-var`)

| Variável Terraform | Obrigatória | Descrição |
|---|---|---|
| `environment` | **Sim** | `dev`, `staging` ou `prod` |
| `aws_region` | Não (default sa-east-1) | Região AWS |
| `vpc_cidr` | Não | CIDR da VPC |

### Para o CI/CD (GitHub Actions Secrets)

| Secret | Onde configurar | Descrição |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Repo Settings → Secrets | Chave de acesso AWS do CI |
| `AWS_SECRET_ACCESS_KEY` | Repo Settings → Secrets | Secret correspondente |

---

## Convenções e regras

- **Nunca commitar `.env` ou arquivos `.tfvars` com valores reais.**
  O `.gitignore` bloqueia, mas o CI também verifica.

- **Todo recurso AWS deve ter as tags padrão** (`Project`, `Environment`, `ManagedBy`).
  O bloco `default_tags` em `versions.tf` aplica automaticamente.

- **Módulos novos** ficam em `terraform/modules/<nome>/` com seus próprios
  `main.tf`, `variables.tf` e `outputs.tf`.

- **Mudanças de infraestrutura sempre via PR** — o workflow `tf-plan.yml` posta
  o plano como comentário. Merge direto em `main` é bloqueado por branch protection.

---

## Gerenciamento de segredos

Ver seção dedicada no README sobre a estratégia de segredos por camada:
- **Local:** `.env` (gitignored) + `.env.example` como template
- **CI/CD:** GitHub Actions Secrets (criptografados pela plataforma)
- **Produção:** AWS Secrets Manager (rotação automática, auditoria via CloudTrail)
