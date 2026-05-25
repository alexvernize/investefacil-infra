# investefacil-infra

Repositório centralizador da infraestrutura do ecossistema **Investefácil**.
Orquestra o backend Go, o frontend Next.js e o banco PostgreSQL localmente via Docker Compose,
e provisiona infraestrutura em nuvem via Terraform.

## Estrutura

```
investefacil-infra/
├── docker-compose.yml       ← orquestração local (postgres + backend + frontend)
├── .env.example             ← template de variáveis — copiar para .env antes de subir
├── PRODUCTION_READY.md      ← roadmap de infraestrutura para produção
├── EXPANSION_ROADMAP.md     ← arquitetura futura: IA Mentor, Explorador de Passado, Mobile
├── terraform/               ← infraestrutura AWS (VPC, subnets, security groups)
└── scripts/
    └── bootstrap.sh         ← cria bucket S3 + tabela DynamoDB para state remoto
```

**Repositórios de aplicação:**

| Repo | Descrição |
|------|-----------|
| [`investefacil`](https://github.com/alexvernize/investefacil) | API Go (simuladores + carteira virtual) |
| [`investefacil-front`](https://github.com/alexvernize/investefacil-front) | Frontend Next.js 16 |

---

## Desenvolvimento local

### Pré-requisitos

- [Docker Desktop](https://docs.docker.com/desktop/) ≥ 4.x (daemon rodando)
- Repositórios `investefacil` e `investefacil-front` clonados como irmãos:

```
projetos/
├── investefacil/
├── investefacil-front/
└── investefacil-infra/   ← você está aqui
```

### Configuração inicial (uma vez)

```bash
cp .env.example .env
# Preencher POSTGRES_PASSWORD no .env
```

O `.env` padrão funciona para desenvolvimento local após preencher `POSTGRES_PASSWORD`.

---

### Subir o ambiente completo

```bash
docker compose up -d --build
```

Ordem de inicialização: `postgres` (aguarda healthcheck) → `backend` → `frontend`.

O banco PostgreSQL é inicializado automaticamente na primeira subida com os scripts de migração do repo `investefacil` (executados em ordem alfabética):

| Script | Conteúdo |
|---|---|
| `001_init.sql` | Schema base: `users`, `wallets`, `transactions` |
| `002_seed.sql` | Usuário demo + carteira R$ 10.000 com UUIDs fixos |
| `003_market_universe.sql` | `equity_tickers`, `equity_prices` |
| `004_wallet_v2.sql` | Campo `asset_class` em `transactions` |
| `005_gamification.sql` | Quiz, `user_stats`, `achievements`, `audit_log`, leaderboards v1 |
| `006_seed_market.sql` | Seed de tickers de mercado |
| `007_seed_quiz.sql` | Seed inicial de perguntas do quiz |
| `008_seed_quiz_real.sql` | Seed de perguntas reais do quiz |
| `009_leaderboards_v2.sql` | Reescreve leaderboards com cálculo em tempo real |
| `010_auth.sql` | `sessions`, `auth_events`, `user_activity`, `users.username` |

### Verificar saúde dos serviços

```bash
docker compose ps
docker compose logs -f
docker compose logs -f backend
docker compose logs -f postgres
```

Endpoints disponíveis após a subida:

| Serviço | URL |
|---------|-----|
| Frontend | http://localhost:3000 |
| Backend API | http://localhost:8080 |
| Health check | http://localhost:8080/healthz |
| Métricas Prometheus | http://localhost:8080/metrics |
| PostgreSQL (direto) | localhost:5432 |

### Derrubar o ambiente

```bash
docker compose down          # para containers, preserva volume do banco
docker compose down -v       # reset completo — apaga banco e reinicia do zero
```

### Rebuild de um único serviço

```bash
docker compose up -d --build backend
docker compose up -d --build frontend
```

---

### Variáveis de ambiente (`.env`)

| Variável | Obrigatória | Exemplo | Descrição |
|---|---|---|---|
| `POSTGRES_PASSWORD` | **Sim** | `trocar_em_prod` | Senha do PostgreSQL |
| `DATABASE_URL` | **Sim** | `postgres://investefacil:senha@postgres:5432/investefacil` | DSN para o backend Go |
| `ALLOWED_ORIGIN` | Sim em produção | `http://localhost:3000` | Origem CORS do frontend |
| `LOG_LEVEL` | Não | `INFO` | Nível de log do backend (`DEBUG`/`INFO`/`WARN`/`ERROR`) |
| `TRUSTED_PROXIES` | Não | `10.0.0.0/8` | CIDRs de proxies confiáveis para IP real |

---

### Validação local antes do push

**Backend (Go):**
```bash
cd ../investefacil
go vet ./...
go test -race ./...
```

**Frontend (Next.js):**
```bash
cd ../investefacil-front
npx tsc --noEmit
npx eslint --max-warnings=0 .
```

---

## Infraestrutura AWS (Terraform)

### Bootstrap — rodar uma única vez por conta AWS

```bash
./scripts/bootstrap.sh
```

### Ciclo normal

```bash
cd terraform
terraform init
terraform plan -var="environment=dev"
terraform apply -var="environment=dev"
```

Consulte `CLAUDE.md` para detalhes completos sobre variáveis, módulos e convenções de recursos.

---

## Roadmaps

| Documento | Conteúdo |
|---|---|
| `PRODUCTION_READY.md` | Redis, Cloud SQL, Brapi, CI/CD, compliance CVM/LGPD |
| `EXPANSION_ROADMAP.md` | Explorador de Passado, Mentor Virtual IA, Mobile Push |
