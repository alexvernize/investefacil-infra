# investefacil-infra — Guia Técnico Completo

## O que é este repositório

Fonte única da verdade para toda a infraestrutura do ecossistema **Investefácil**.
Orquestra os três serviços localmente via Docker Compose e provisiona infraestrutura AWS via Terraform.

**Repositórios relacionados (ficam em `../` em relação a este repo):**
- `../investefacil` — Backend Go (API)
- `../investefacil-front` — Frontend Next.js

---

## Estrutura de diretórios

```
investefacil-infra/
├── docker-compose.yml         ← Orquestração local completa (postgres + backend + frontend)
├── .env                       ← Variáveis locais (gitignored — nunca commitar)
├── .env.example               ← Template de variáveis
├── .gitignore
├── CLAUDE.md
├── PRODUCTION_READY.md        ← Roadmap técnico: Redis, Cloud SQL, Brapi, CVM compliance (status atualizado)
├── EXPANSION_ROADMAP.md       ← Arquitetura futura: Explorador de Passado, Mentor Virtual IA, Mobile Push
├── terraform/
│   ├── versions.tf            ← Provider AWS + backend S3/DynamoDB para state remoto
│   ├── variables.tf           ← Todas as variáveis com validação
│   ├── main.tf                ← VPC, subnets, IGW, NAT, security groups
│   └── outputs.tf             ← IDs e IPs exportados
└── scripts/
    └── bootstrap.sh           ← Cria S3 bucket + DynamoDB (rodar UMA VEZ por conta AWS)
```

---

## Docker Compose — Arquitetura local

```
                     localhost
                        │
           ┌────────────┼────────────┐
           │            │            │
        :3000         :8080        :5432
           │            │            │
      [frontend]    [backend]   [postgres]
      Next.js        Go API      PG 16 Alpine
           │            │            │
      frontend-net  backend-net  internal_bridge (internal:true)
           └────────────┘            │
                                     └── apenas backend acessa
```

### Volumes e inicialização do PostgreSQL
O Postgres monta `../investefacil/scripts/migrations/` em `docker-entrypoint-initdb.d/`.
Scripts executados **em ordem alfabética** apenas na **primeira inicialização do volume**:

1. `001_init.sql` — cria extensão pgcrypto, tabelas `users`, `wallets`, `transactions`
2. `002_seed.sql` — insere usuário demo + carteira R$ 10.000 com UUIDs fixos

Se o volume já existir, os scripts não rodam novamente. Para resetar o schema:
```bash
docker compose down -v   # destrói volume pg_data
docker compose up -d     # recria do zero
```

### Redes isoladas (segurança)
- `internal_bridge` com `internal: true` — Postgres **não tem acesso à internet**. Só o backend conecta.
- `backend-net` — backend ↔ frontend. Não é internal (backend precisa chamar API do BCB).
- `frontend-net` — isolamento do frontend.
- Todas as portas fazem bind em `127.0.0.1` — inacessíveis de outras interfaces de rede.

---

## Variáveis de ambiente (`.env`)

Copiar de `.env.example` antes do primeiro uso:
```bash
cp .env.example .env
```

| Variável | Obrigatória | Exemplo | Descrição |
|---|---|---|---|
| `POSTGRES_PASSWORD` | **Sim** | `trocar_em_prod` | Senha do PostgreSQL |
| `DATABASE_URL` | **Sim** | `postgres://investefacil:senha@postgres:5432/investefacil` | DSN completo para o backend Go |
| `PORT` | Não | `8080` | Porta do backend (default 8080) |
| `ALLOWED_ORIGIN` | Sim em produção | `http://localhost:3000` | Origem CORS do frontend |
| `LOG_LEVEL` | Não | `INFO` | Nível de log do backend (`DEBUG`/`INFO`/`WARN`/`ERROR`) |
| `TRUSTED_PROXIES` | Não | `172.16.0.0/12` | CIDRs CSV de proxies para extração de IP real |

**Atenção:** `ALLOWED_ORIGIN="*"` causa `os.Exit(1)` no backend — o container reinicia infinitamente.
Sempre use a URL real do frontend.

---

## Comandos do dia a dia

```bash
# Primeiro uso
cp .env.example .env        # preencher POSTGRES_PASSWORD e DATABASE_URL

# Subir tudo
docker compose up --build   # build + up em foreground
docker compose up -d        # background

# Logs
docker compose logs -f
docker compose logs -f backend
docker compose logs -f postgres

# Rebuild após mudança de código
docker compose up -d --build backend
docker compose up -d --build frontend

# Reset completo (destrói banco)
docker compose down -v && docker compose up --build

# Parar sem destruir volume
docker compose down
```

### Endpoints locais após `docker compose up`
| Serviço | URL |
|---|---|
| Frontend | http://localhost:3000 |
| Backend API | http://localhost:8080 |
| Health check | http://localhost:8080/healthz |
| PostgreSQL | localhost:5432 (apenas tools locais como TablePlus/psql) |

### Conectar no PostgreSQL manualmente
```bash
psql postgresql://investefacil:${POSTGRES_PASSWORD}@localhost:5432/investefacil
```

---

## Terraform — AWS

### Pré-requisitos
```bash
brew install terraform tflint awscli
aws configure   # ou: export AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY
```

### Bootstrap (rodar UMA VEZ por conta AWS)
Cria o bucket S3 e a tabela DynamoDB para state remoto:
```bash
./scripts/bootstrap.sh
```

### Ciclo normal
```bash
cd terraform
terraform init
terraform validate
tflint --init && tflint
terraform plan -var="environment=dev"
terraform apply -var="environment=dev"
```

### Secrets (nunca commitar `.tfvars` com valores reais)
- Local: `.env` (gitignored)
- CI/CD: GitHub Actions Secrets
- Produção: AWS Secrets Manager

---

## CI/CD (GitHub Actions)

| Workflow | Trigger | O que faz |
|---|---|---|
| `tf-plan.yml` | PR para main | `terraform plan` + posta resultado como comentário |
| `tf-apply.yml` | Merge para main | `terraform apply` com aprovação manual |

Secrets necessários no repositório: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`.

---

## Próximos passos de infraestrutura

Ver `PRODUCTION_READY.md` para o roadmap completo e `EXPANSION_ROADMAP.md` para a expansão de IA e Mobile.

| Prioridade | Item | Documento |
|---|---|---|
| ✅ Feito | Logs JSON estruturados (slog) | — |
| ✅ Feito | Métricas Prometheus + /metrics | — |
| ✅ Feito | Gamificação (badges, ranking, reset) | — |
| 🔴 Crítico | Audit log imutável (compliance CVM) | PRODUCTION_READY.md |
| 🔴 Crítico | GCP Secret Manager (remover senhas do `.env`) | PRODUCTION_READY.md |
| 🔴 Crítico | TLS/HTTPS no Load Balancer | PRODUCTION_READY.md |
| 🟠 Alta | Redis (Cloud Memorystore) para cache de taxas | PRODUCTION_READY.md |
| 🟠 Alta | Integração Brapi para preços reais de ações | PRODUCTION_READY.md |
| 🟠 Alta | Tabelas stock_prices + stock_dividends (prerequisito expansão) | EXPANSION_ROADMAP.md |
| 🟡 Média | VPC isolada para Cloud SQL + Redis sem IP público | PRODUCTION_READY.md |
| 🟡 Média | Health check com verificação de dependências | PRODUCTION_READY.md |
| 🟢 Baixa | Mentor Virtual IA (Anthropic API) | EXPANSION_ROADMAP.md |
| 🟢 Baixa | Notificações Push de Proventos (FCM) | EXPANSION_ROADMAP.md |
| 🟢 Baixa | OCR de Notas de Corretagem (microsserviço Python) | EXPANSION_ROADMAP.md |
