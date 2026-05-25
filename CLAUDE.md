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
├── Makefile                   ← Alvos de orquestração: start, back, front, migrate, reset, rebuild
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
Scripts executados **em ordem alfabética** apenas na **primeira inicialização do volume**.

**16 migrations em ordem de execução:**

| Arquivo | Conteúdo |
|---|---|
| `001_init.sql` | Extensão pgcrypto, tabelas `users`, `wallets`, `transactions` |
| `002_seed.sql` | Usuário demo + carteira R$ 10.000 com UUIDs fixos |
| `003_market_universe.sql` | `equity_tickers`, `equity_prices` |
| `004_wallet_v2.sql` | `asset_class` em `transactions` (EQUITY/FIXED_INCOME) |
| `005_gamification.sql` | Quiz, `user_stats`, achievements, leaderboards v1 |
| `006_seed_market.sql` | Seed de tickers de mercado |
| `007_seed_quiz.sql` | Seed inicial de perguntas do quiz |
| `008_seed_quiz_real.sql` | Seed de perguntas reais |
| `009_leaderboards_v2.sql` | Reescreve leaderboards com normalização por posição |
| `010_auth.sql` | `sessions`, `auth_events`, `user_activity`, `users.username` |
| `011_allowance.sql` | `allowance_log`, `dividend_events`, `dividend_payments` |
| `012_show_demo.sql` | `users.show_demo BOOLEAN DEFAULT TRUE` |
| `013_gamification_v2.sql` | `user_stats.level`, `xp`, `investor_profile` |
| `014_missions.sql` | `missions`, `user_missions`, seed de 3 missões |
| `015_lessons.sql` | `lessons` (catálogo de lições), `user_lessons` (conclusões + XP) |
| `016_market_assets.sql` | `market_assets` (cache de ativos B3/Tesouro via Brapi) |

**Atenção:** Migrations rodam só na primeira inicialização do volume. Para reaplicar ao volume existente, use `make migrate`. Para resetar o schema do zero, use `make reset`.

### Redes isoladas (segurança)

- `internal_bridge` com `internal: true` — Postgres **não tem acesso à internet**. Só o backend conecta.
- `backend-net` — backend ↔ frontend. Não é internal (backend precisa chamar API do BCB).
- `frontend-net` — isolamento do frontend.
- Todas as portas fazem bind em `127.0.0.1` — inacessíveis de outras interfaces de rede.

---

## Makefile — Alvos disponíveis

```bash
make start    # limpa conflitos + rebuild total sem cache + sobe + aplica migrations
make up       # sobe os serviços sem rebuildar (stack já tem imagens)
make down     # derruba o stack e remove órfãos (preserva volume do banco)
make clean    # down + remoção forçada dos containers por nome
make back     # rebuild sem cache só do backend + recria só ele (stack no ar)
make front    # rebuild sem cache só do frontend + recria só ele (stack no ar)
make migrate  # aplica todas as migrations no Postgres em execução (idempotentes com BEGIN/COMMIT)
make reset    # APAGA volume do banco + rebuild total + sobe do zero (migrations rodam no init)
make rebuild  # rebuild sem cache de tudo, sem apagar o banco, sem rodar migrate
make logs     # segue os logs de todos os serviços
make ps       # status dos containers
make help     # lista os alvos disponíveis
```

**Diferença entre `start` e `reset`:**
- `make start`: preserva o volume; rebuild das imagens; aplica migrations com `psql` (idempotentes). Use quando só o código mudou.
- `make reset`: destrói o volume; rebuild das imagens; postgres re-executa todas as migrations automaticamente via `initdb`. Use quando o schema mudou de forma incompatível.

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
| `BRAPI_TOKEN` | Não | `<token>` | Token da API Brapi (brapi.dev) — sem token, rate-limit por IP |

**Atenção:** `ALLOWED_ORIGIN="*"` causa `os.Exit(1)` no backend — o container reinicia infinitamente.
Sempre use a URL real do frontend.

---

## Comandos do dia a dia

```bash
# Primeiro uso
cp .env.example .env        # preencher POSTGRES_PASSWORD e DATABASE_URL
make start                  # build completo + up + migrate

# Fluxo normal de desenvolvimento
make back                   # só o backend mudou
make front                  # só o frontend mudou
make migrate                # nova migration adicionada, volume existente

# Logs
make logs
docker compose logs -f backend
docker compose logs -f postgres

# Reset completo (destrói banco)
make reset

# Parar sem destruir volume
make down
```

### Endpoints locais após `make start`

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

### Reset rápido de dados em desenvolvimento (sem destruir o schema)

```bash
psql postgresql://investefacil:${POSTGRES_PASSWORD}@localhost:5432/investefacil \
  -f ../investefacil/scripts/reset-dev.sql
```

O arquivo `reset-dev.sql` faz `TRUNCATE TABLE transactions, wallets, users CASCADE` — remove dados mas preserva o schema e as migrations aplicadas.

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
| ✅ Feito | Gamificação (badges, ranking, reset, XP, níveis, streak) | — |
| ✅ Feito | Missões DAILY/WEEKLY com progresso por período | — |
| ✅ Feito | Worker de mesada R$ 250/semana (idempotente, multi-instance-safe) | — |
| ✅ Feito | Rebalanceamento de carteira por categoria | — |
| ✅ Feito | Feed Educativo de lições com XP validado no servidor | — |
| ✅ Feito | Inventário dinâmico de ativos (lazy loading via Brapi) — `market_assets` | — |
| 🔴 Crítico | Audit log imutável (compliance CVM) | PRODUCTION_READY.md |
| 🔴 Crítico | GCP Secret Manager (remover senhas do `.env`) | PRODUCTION_READY.md |
| 🔴 Crítico | TLS/HTTPS no Load Balancer | PRODUCTION_READY.md |
| 🟠 Alta | Redis (Cloud Memorystore) para cache de taxas | PRODUCTION_READY.md |
| 🟠 Alta | CRON diário para `RefreshAll()` — atualizar preços em `market_assets` (backend pronto) | PRODUCTION_READY.md |
| 🟠 Alta | Tabelas stock_prices + stock_dividends (prerequisito expansão) | EXPANSION_ROADMAP.md |
| 🟡 Média | VPC isolada para Cloud SQL + Redis sem IP público | PRODUCTION_READY.md |
| 🟡 Média | Health check com verificação de dependências | PRODUCTION_READY.md |
| 🟢 Baixa | Mentor Virtual IA (Anthropic API) | EXPANSION_ROADMAP.md |
| 🟢 Baixa | Notificações Push de Proventos (FCM) | EXPANSION_ROADMAP.md |
| 🟢 Baixa | OCR de Notas de Corretagem (microsserviço Python) | EXPANSION_ROADMAP.md |
