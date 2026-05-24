# PRODUCTION_READY — Roadmap de Infraestrutura

Guia estratégico de engenharia para mover a plataforma `investefacil` do estado de MVP
(mocks locais, cache em memória, dados históricos estáticos) para um ambiente produtivo
seguro, escalável e aderente às exigências regulatórias aplicáveis.

---

## 1. Persistência e Cache Distribuído

### Problema atual

O cache de taxas de mercado (CDI/Selic) vive em memória RAM com `sync.Mutex`:

```go
// internal/market/bcb.go — estado atual
type rateCache struct {
    mu        sync.Mutex
    data      *MarketRates
    fetchedAt time.Time
}
```

Em um ambiente multi-container (GCP Cloud Run com N instâncias), cada réplica mantém seu próprio cache. Isso causa:
- Requisições excessivas à API do BCB (uma por réplica a cada TTL).
- Inconsistência de taxas entre instâncias no mesmo segundo.
- Estado perdido em cada cold start do container.

### Solução: Redis como cache distribuído

**Tecnologia**: Cloud Memorystore (Redis gerenciado no GCP), dentro da VPC privada.

**Implementação no backend:**

```go
// internal/market/cache.go
type RedisCache struct {
    client *redis.Client
    ttl    time.Duration
}

func (c *RedisCache) GetRates(ctx context.Context) (*MarketRates, error) {
    val, err := c.client.Get(ctx, "market:rates").Result()
    if err == redis.Nil {
        return nil, ErrCacheMiss
    }
    // ...
}

func (c *RedisCache) SetRates(ctx context.Context, rates *MarketRates) error {
    data, _ := json.Marshal(rates)
    return c.client.Set(ctx, "market:rates", data, c.ttl).Err()
}
```

**Configuração:**
- TTL: 15 minutos (taxa CDI/Selic muda uma vez por reunião do COPOM, ~a cada 45 dias).
- Fallback: se Redis indisponível, o handler busca direto no BCB e loga o evento.
- Conexão via socket Unix ou VPC interna — nunca expor Redis publicamente.

### Banco de dados: PostgreSQL para carteiras de usuários

**Tecnologia**: Cloud SQL (PostgreSQL 15 gerenciado no GCP), instância `db-g1-small` para MVP.

**Schema inicial:**

```sql
CREATE TABLE users (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email       TEXT UNIQUE NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE simulations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    module          TEXT NOT NULL CHECK (module IN ('renda_fixa', 'renda_variavel')),
    input_payload   JSONB NOT NULL,
    result_payload  JSONB NOT NULL,
    simulated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_simulations_user_id ON simulations(user_id);
CREATE INDEX idx_simulations_simulated_at ON simulations(simulated_at DESC);
```

**Interface de repositório (clean architecture):**

```go
// internal/repository/simulation.go
type SimulationRepository interface {
    Save(ctx context.Context, userID uuid.UUID, module string, input, result any) error
    ListByUser(ctx context.Context, userID uuid.UUID, limit int) ([]SimulationRecord, error)
}
```

O handler recebe o repositório por injeção de dependência via `main.go`. O `domain/` e os engines de cálculo não tocam em banco de dados.

**Biblioteca recomendada**: `pgx/v5` (sem ORM — queries explícitas são mais auditáveis em contexto financeiro).

---

## 2. Integração Real de Dados de Mercado

### Problema atual

Os preços históricos de ações e dividendos estão em `internal/equity/data.go` como arrays estáticos. São aproximações calculadas — não cotações reais da B3.

### Interface de abstração (`internal/equity/provider.go`)

O primeiro passo é encapsular os dados atrás de uma interface, sem mudar o engine:

```go
type StockProvider interface {
    // Retorna preços mensais de fechamento dos últimos N meses.
    FetchMonthlyPrices(ctx context.Context, ticker string, months int) ([]float64, error)
    // Retorna proventos (dividendos + JCP) pagos nos últimos N meses.
    FetchDividends(ctx context.Context, ticker string, months int) ([]Dividend, error)
}

// Implementação atual (dados estáticos)
type MockProvider struct{}

// Implementação futura (dados reais)
type BrapiProvider struct {
    apiKey  string
    baseURL string
    cache   *RedisCache
}
```

`engine.go` passa a receber `StockProvider` por injeção de dependência. Os testes continuam usando `MockProvider`.

### Provedores avaliados para integração real

| Provedor | Tipo | Cobertura | Observações |
|---|---|---|---|
| **Brapi** (brapi.dev) | API REST | Preços históricos, dividendos, info corporativa | Plano gratuito com rate limit; plano pago para volume |
| **HG Brasil** (hgbrasil.com) | API REST | Preços, índices, cotações | Boa documentação, suporte a múltiplos tickers por request |
| **StatusInvest** | Scraping | Dividendos históricos detalhados | HTML scraping frágil; violar ToS é risco legal — evitar |
| **B3 Market Data** | Licenciado | Dados oficiais em tempo real | Custo alto; para quando houver volume justificável |

**Recomendação MVP → Produção**: Brapi para preços históricos + dividendos dos 10 tickers do universo atual. Cache de 24h no Redis (dados históricos não mudam). Cotação em tempo real (preço atual) com TTL de 15 minutos.

### Pipeline de enriquecimento de dados

```
Brapi API
  ↓ BrapiProvider.FetchMonthlyPrices(ctx, "PETR3", 24)
  ↓ RedisCache.Get("prices:PETR3:24m")   ← hit → retorna imediato
  ↓ Brapi HTTP call                       ← miss → busca e armazena
  ↓ equity.Simulate(input, provider)
  ↓ EquitySimulationResponse
```

---

## 3. Segurança e Criptografia

### Problema atual

Variáveis de ambiente em texto plano no arquivo `.env`:

```bash
# investefacil-infra/.env — NÃO fazer em produção
POSTGRES_PASSWORD=minhasenha123
REDIS_URL=redis://localhost:6379
BCB_API_KEY=abc123
```

### GCP Secret Manager

Migração para o ecossistema de secrets já utilizado no projeto Volis:

```bash
# Criar secrets
gcloud secrets create investefacil-db-password --replication-policy=automatic
echo -n "senha_forte_gerada" | gcloud secrets versions add investefacil-db-password --data-file=-

gcloud secrets create investefacil-redis-url --replication-policy=automatic
gcloud secrets create investefacil-brapi-key --replication-policy=automatic
```

**Acesso no Cloud Run:**

```yaml
# cloud-run-service.yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: investefacil-db-password
        key: latest
  - name: REDIS_URL
    valueFrom:
      secretKeyRef:
        name: investefacil-redis-url
        key: latest
```

**Service Account** com permissão mínima `roles/secretmanager.secretAccessor` — nunca `roles/owner`.

### Criptografia em repouso

| Dado | Mecanismo | Implementação |
|---|---|---|
| Dados no Cloud SQL | Encryption at rest (padrão GCP) | Automático — chave gerenciada pelo Google |
| Chaves de criptografia de campos sensíveis | CMEK (Customer-Managed Encryption Keys) | Cloud KMS — para dados de carteira do usuário |
| Senhas de usuário | `bcrypt` (cost ≥ 12) | `golang.org/x/crypto/bcrypt` |
| Tokens de sessão | `crypto/rand` + HMAC-SHA256 | Assinar com secret do Secret Manager |
| Dados em trânsito | TLS 1.2+ | Terminado no Load Balancer do Cloud Run |

**Campos sensíveis no banco** (criptografia de aplicação além da criptografia de disco):

```go
// Para e-mail e dados pessoais — AES-256-GCM com chave do KMS
func encryptField(plaintext string, key []byte) (string, error) {
    block, _ := aes.NewCipher(key)
    gcm, _   := cipher.NewGCM(block)
    nonce    := make([]byte, gcm.NonceSize())
    io.ReadFull(rand.Reader, nonce)
    ciphertext := gcm.Seal(nonce, nonce, []byte(plaintext), nil)
    return base64.StdEncoding.EncodeToString(ciphertext), nil
}
```

---

## 4. Resiliência de Infraestrutura

### GCP Cloud Run — Estratégia de Deploy

**Configuração recomendada para o serviço de API:**

```yaml
# cloud-run-api.yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: investefacil-api
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "1"         # evitar cold start em horário comercial
        autoscaling.knative.dev/maxScale: "10"
        autoscaling.knative.dev/target: "80"           # 80 req concorrentes por instância
        run.googleapis.com/vpc-access-connector: "investefacil-connector"
        run.googleapis.com/vpc-access-egress: "private-ranges-only"
    spec:
      containers:
        - image: gcr.io/PROJECT_ID/investefacil:latest
          resources:
            limits:
              cpu: "1"
              memory: "512Mi"
          livenessProbe:
            httpGet:
              path: /healthz
            initialDelaySeconds: 3
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz
            initialDelaySeconds: 2
            periodSeconds: 5
```

**Parâmetros de auto-scaling:**
- `minScale: 1` — mantém uma instância quente; aceita tráfego sem cold start.
- `maxScale: 10` — limite de custo; revisar conforme crescimento de usuários.
- `target: 80` — Cloud Run escala quando concorrência por instância ultrapassa 80 req.

### Health Check robusto

O `/healthz` atual retorna apenas `{"status":"ok"}`. Em produção deve verificar dependências:

```go
// cmd/api/main.go — healthz aprimorado
func healthzHandler(db *sql.DB, redis *redis.Client) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
        defer cancel()

        checks := map[string]string{"api": "ok"}

        if err := db.PingContext(ctx); err != nil {
            checks["database"] = "error: " + err.Error()
        } else {
            checks["database"] = "ok"
        }

        if err := redis.Ping(ctx).Err(); err != nil {
            checks["cache"] = "error: " + err.Error()
        } else {
            checks["cache"] = "ok"
        }

        status := http.StatusOK
        for _, v := range checks {
            if v != "ok" {
                status = http.StatusServiceUnavailable
                break
            }
        }

        w.Header().Set("Content-Type", "application/json")
        w.WriteHeader(status)
        json.NewEncoder(w).Encode(checks)
    }
}
```

### Isolamento de VPC

```
Internet
  ↓ HTTPS
Cloud Load Balancer (Global, gerenciado pelo GCP)
  ↓ HTTP interno
Cloud Run (API) — apenas tráfego de saída para ranges privados
  ↓ VPC Connector (investefacil-connector)
VPC Privada (10.0.0.0/16)
  ├── Cloud SQL (subnet 10.0.1.0/24) — sem IP público
  └── Cloud Memorystore/Redis (subnet 10.0.2.0/24) — sem IP público
```

**Regras de firewall:**
- Cloud SQL aceita conexões apenas do service account do Cloud Run.
- Redis aceita conexões apenas do IP range do VPC Connector.
- Nenhum serviço interno expõe porta ao exterior.

### Pipeline CI/CD (GitHub Actions)

```yaml
# .github/workflows/deploy.yml
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: google-github-actions/auth@v2
        with:
          credentials_json: ${{ secrets.GCP_SA_KEY }}
      - name: Build and push
        run: |
          docker build -t gcr.io/$PROJECT_ID/investefacil:$GITHUB_SHA .
          docker push gcr.io/$PROJECT_ID/investefacil:$GITHUB_SHA
      - name: Deploy to Cloud Run
        run: |
          gcloud run deploy investefacil-api \
            --image gcr.io/$PROJECT_ID/investefacil:$GITHUB_SHA \
            --region us-central1 \
            --platform managed \
            --no-traffic          # blue/green: deploy sem tráfego
      - name: Smoke test
        run: |
          URL=$(gcloud run services describe investefacil-api --format='value(status.url)')
          curl -f $URL/healthz
      - name: Migrate traffic
        run: |
          gcloud run services update-traffic investefacil-api \
            --to-latest \
            --region us-central1
```

---

## 5. Conformidade Regulatória (CVM / ANBIMA)

### Contexto regulatório

A plataforma `investefacil` apresenta simulações de investimento a pessoas físicas. Embora não seja uma corretora ou consultora de valores mobiliários, ao comparar e recomendar ativos deve observar:

- **Resolução CVM 30/2021** (atualização da Instrução 539): suitability obrigatório para recomendação de ativos a clientes de varejo.
- **ANBIMA — Código de Distribuição**: requisitos de adequação de perfil e transparência de informações.
- **LGPD**: dados pessoais dos usuários (incluindo histórico de simulações) são dados pessoais e precisam de consentimento explícito e base legal de tratamento.

### Trilha de Auditoria Imutável

Toda simulação realizada por um usuário deve ser registrada de forma imutável para fins de:
1. **Suitability**: evidência de que o usuário recebeu informação adequada antes de decidir.
2. **Rastreabilidade**: em caso de contestação regulatória, reproduzir o cálculo exato que o usuário viu.

**Schema de audit log:**

```sql
CREATE TABLE audit_log (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id),
    event_type      TEXT NOT NULL,     -- 'simulation_created', 'user_registered', etc.
    module          TEXT,              -- 'renda_fixa', 'renda_variavel'
    input_snapshot  JSONB NOT NULL,    -- cópia imutável do input exato
    result_snapshot JSONB NOT NULL,    -- cópia imutável do resultado exato
    ip_address      INET,
    user_agent      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Sem UPDATE, sem DELETE — append-only
REVOKE UPDATE, DELETE ON audit_log FROM investefacil_app;
```

**No backend — registrar antes de retornar ao cliente:**

```go
func (h *EquityHandler) Simulate(w http.ResponseWriter, r *http.Request) {
    // ... decode, validate, calculate ...
    result, _ := equity.Simulate(input)

    // Audit log gravado de forma assíncrona — não bloqueia response
    go h.auditRepo.Append(context.Background(), AuditEvent{
        UserID:         userID,
        EventType:      "simulation_created",
        Module:         "renda_variavel",
        InputSnapshot:  input,
        ResultSnapshot: result,
        IPAddress:      realIP(r),
        UserAgent:      r.Header.Get("User-Agent"),
    })

    json.NewEncoder(w).Encode(result)
}
```

**Imutabilidade garantida em múltiplas camadas:**
- Permissão de banco revogada para `UPDATE`/`DELETE` no usuário da aplicação.
- Tabela sem trigger de atualização.
- Em nível superior: considerar exportar logs para Cloud Storage (bucket com Object Versioning) como backup imutável adicional.

### Isenção de Responsabilidade (Disclaimer)

Toda simulação deve ser acompanhada de aviso regulatório visível:

```
"As simulações apresentadas têm caráter meramente informativo e educacional.
Rentabilidade passada não é garantia de rentabilidade futura.
Valores mobiliários de renda variável estão sujeitos a riscos de mercado.
Esta plataforma não constitui consultoria de valores mobiliários nos termos da
Resolução CVM 19/2021. Consulte um profissional certificado antes de investir."
```

O campo `aviso` já existe no response de renda variável — deve ser expandido e exibido de forma proeminente no frontend.

### Suitability — Questionário de Perfil

Para conformidade com a Resolução CVM 30/2021, implementar antes de liberar acesso a produtos de renda variável:

```go
// internal/suitability/profile.go
type InvestorProfile struct {
    UserID          uuid.UUID
    Objective       string   // "preservacao" | "renda" | "crescimento" | "especulacao"
    Horizon         string   // "curto" | "medio" | "longo"
    RiskTolerance   string   // "conservador" | "moderado" | "arrojado"
    Experience      string   // "iniciante" | "intermediario" | "experiente"
    FinancialSituation string
    AssessedAt      time.Time
    ExpiresAt       time.Time // suitability expira em 24 meses (ANBIMA)
}
```

O resultado do questionário deve ser armazenado no banco, assinado digitalmente com timestamp e renovado a cada 24 meses.

---

## Resumo de Prioridades

| Prioridade | Item | Complexidade | Impacto |
|---|---|---|---|
| 🔴 Crítico | Audit log imutável de simulações | Média | Compliance CVM |
| 🔴 Crítico | GCP Secret Manager (remover .env) | Baixa | Segurança |
| 🔴 Crítico | TLS + HTTPS no Load Balancer | Baixa | Segurança |
| 🟠 Alta | Redis para cache distribuído | Média | Escalabilidade |
| 🟠 Alta | PostgreSQL para histórico de usuários | Alta | Produto |
| 🟠 Alta | Integração Brapi (preços reais) | Alta | Confiabilidade dos dados |
| 🟡 Média | Isolamento VPC (SQL + Redis sem IP público) | Média | Segurança |
| 🟡 Média | Health check com dependências | Baixa | Observabilidade |
| 🟡 Média | Rate limiting por IP (não global) | Média | Proteção DoS |
| 🟢 Baixa | Suitability / questionário de perfil | Alta | Compliance ANBIMA |
| 🟢 Baixa | CMEK para campos pessoais | Alta | Segurança avançada |
| 🟢 Baixa | Métricas Prometheus + Cloud Monitoring | Média | Observabilidade |

---

## Estimativa de Custo Mensal (GCP, MVP de Produção)

| Serviço | SKU | Estimativa |
|---|---|---|
| Cloud Run (API) | 1 instância mínima, ~2M req/mês | ~USD 10–30 |
| Cloud SQL (PostgreSQL) | `db-g1-small`, 10 GB SSD | ~USD 25 |
| Cloud Memorystore (Redis) | `M1` 1 GB | ~USD 35 |
| Cloud Load Balancer | 1 regra de encaminhamento | ~USD 18 |
| Cloud Storage (audit logs) | 10 GB | ~USD 0.23 |
| Secret Manager | < 10k acessos/mês | ~USD 0.06 |
| **Total estimado** | | **~USD 90–110/mês** |

Valores aproximados baseados na tabela de preços GCP de mai/2026. Revisar com `gcloud billing budgets create` para alerta de orçamento antes do go-live.
