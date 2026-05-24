# PRODUCTION_READY — Roadmap de Infraestrutura

Guia estratégico para mover a plataforma `investefacil` do estado MVP para um ambiente produtivo
seguro, escalável e aderente às exigências regulatórias aplicáveis.

**Estado atual (mai/2026):** MVP funcional com PostgreSQL local, logs JSON estruturados (`slog`),
métricas Prometheus, gamificação (badges + ranking + reset) e observabilidade frontend (error
boundaries, WebVitals, telemetria de erros).

---

## Status de cada item

| Status | Significado |
|---|---|
| ✅ Feito | Implementado e em produção ou ambiente local |
| 🔴 Crítico | Bloqueador para go-live em produção |
| 🟠 Alta | Necessário antes de escalar usuários |
| 🟡 Média | Importante, mas sem bloqueio imediato |
| 🟢 Baixa | Melhoria futura |

---

## 1. Observabilidade ✅ Feito

### Logs estruturados (`log/slog`)

`telemetry.Init()` configura `slog.NewJSONHandler` com campo `service_name` fixo no root logger.
Nível controlado por `LOG_LEVEL` env var (`DEBUG`/`INFO`/`WARN`/`ERROR`). Todo log sai com
atributo `component` para filtragem em ferramentas como Cloud Logging ou Loki.

Exemplo de linha de log:
```json
{"time":"2026-05-24T10:00:00Z","level":"INFO","service_name":"investefacil-api","msg":"http.request","component":"http","http.method":"GET","http.url_path":"/api/v1/wallet","http.status_code":200,"http.duration_ms":3,"network.client_ip":"127.0.0.1"}
```

### Métricas Prometheus (`/metrics`)

| Métrica | Tipo | Labels |
|---|---|---|
| `http_requests_total` | Counter | `method`, `endpoint`, `status` |
| `http_request_duration_seconds` | Histogram (buckets 5ms→2,5s) | `method`, `endpoint` |
| `wallet_transactions_total` | Counter | `type` (BUY/SELL), `status` (SUCCESS/FAILED) |
| `db_pool_connections_total/acquired/idle/max` | Gauge | — |
| `db_pool_acquire_total`, `empty_acquire_total` | Counter | — |
| `db_pool_acquire_duration_seconds_total` | Counter | — |

**Guardrail de segurança para `/metrics` em produção:**
- Opção 1 (recomendada): isolar a rota em porta separada (ex: `9090`) acessível apenas pelo IP do Prometheus via regra de firewall.
- Opção 2: middleware de IP allowlist usando `METRICS_ALLOWED_CIDR` env var.

### Observabilidade Frontend ✅ Feito

- `src/app/error.tsx` + `global-error.tsx` — Error Boundaries do App Router com UI de fallback.
- `logClientTelemetry` em `src/lib/api.ts` — fire-and-forget para `POST /api/v1/telemetry/frontend-errors`.
- `src/components/WebVitals.tsx` — TTFB, FCP e LCP via PerformanceObserver nativo.

---

## 2. Persistência e Cache Distribuído

### PostgreSQL ✅ Feito (local/dev)

Schema em `investefacil/scripts/migrations/`. Pool `pgx/v5` com `Ping` no boot.
**Pendente para produção:** migrar para Cloud SQL (PostgreSQL 15+) com IP privado na VPC.

### Cache distribuído para taxas de mercado 🟠 Alta

**Problema:** cache CDI/Selic vive em memória RAM com `sync.Mutex`. Em ambiente multi-container,
cada réplica mantém cache independente — requisições excessivas ao BCB e inconsistência entre instâncias.

**Solução: Cloud Memorystore (Redis gerenciado no GCP)**

```go
// internal/market/cache.go
type RedisCache struct {
    client *redis.Client
    ttl    time.Duration  // 15 minutos — CDI muda apenas em reuniões do COPOM (~45 dias)
}

func (c *RedisCache) GetRates(ctx context.Context) (*MarketRates, error) {
    val, err := c.client.Get(ctx, "market:rates").Result()
    if errors.Is(err, redis.Nil) { return nil, ErrCacheMiss }
    // unmarshal e retornar
}
```

Fallback: se Redis indisponível, busca direto no BCB e loga o evento.

---

## 3. Dados Reais de Mercado 🟠 Alta

**Problema atual:** preços históricos de ações em `internal/equity/data.go` são aproximações — não cotações reais da B3.

### Interface de abstração

```go
// internal/equity/provider.go
type StockProvider interface {
    FetchMonthlyPrices(ctx context.Context, ticker string, months int) ([]float64, error)
    FetchDividends(ctx context.Context, ticker string, months int) ([]Dividend, error)
}
// data.go → MockProvider (sem mudança)
// BrapiProvider → implementa a mesma interface com dados reais
// engine.go recebe StockProvider por injeção de dependência
```

### Provedores avaliados

| Provedor | Tipo | Cobertura | Observação |
|---|---|---|---|
| **Brapi** (brapi.dev) | API REST | Preços históricos, dividendos, info corporativa | Plano gratuito com rate limit |
| **HG Brasil** (hgbrasil.com) | API REST | Preços, índices, cotações | Suporte a múltiplos tickers por request |
| **B3 Market Data** | Licenciado | Dados oficiais em tempo real | Alto custo — justificável com volume |

**Recomendação:** Brapi para MVP → produção. Cache Redis 24h para preços históricos; 15min para cotação atual.

---

## 4. Segurança e Gestão de Secrets 🔴 Crítico

**Problema atual:** variáveis de ambiente em texto plano no `.env`.

### GCP Secret Manager

```bash
gcloud secrets create investefacil-db-password --replication-policy=automatic
echo -n "senha_forte" | gcloud secrets versions add investefacil-db-password --data-file=-
```

**No Cloud Run:**
```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: investefacil-db-password
        key: latest
```

Service Account com `roles/secretmanager.secretAccessor` — nunca `roles/owner`.

### Criptografia em repouso

| Dado | Mecanismo |
|---|---|
| Dados no Cloud SQL | Encryption at rest (padrão GCP) |
| Senhas de usuário | `bcrypt` (cost ≥ 12) |
| Tokens de sessão | `crypto/rand` + HMAC-SHA256 |
| Dados em trânsito | TLS 1.2+ no Load Balancer |
| Campos pessoais | AES-256-GCM com chave do Cloud KMS (CMEK) |

---

## 5. Resiliência de Infraestrutura

### GCP Cloud Run 🟡 Média

```yaml
autoscaling.knative.dev/minScale: "1"   # evitar cold start em horário comercial
autoscaling.knative.dev/maxScale: "10"
autoscaling.knative.dev/target: "80"    # 80 req concorrentes por instância
```

### Health check com dependências 🟡 Média

O `/healthz` atual retorna `{"status":"ok"}` sem verificar dependências. Em produção:

```go
func healthzHandler(db *pgxpool.Pool, redis *redis.Client) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
        defer cancel()
        checks := map[string]string{"api": "ok"}
        if err := db.Ping(ctx); err != nil { checks["database"] = "error: " + err.Error() }
        // ...verificar redis...
        // retornar 503 se qualquer check falhar
    }
}
```

### Isolamento VPC 🟡 Média

```
Internet → Cloud Load Balancer
  → Cloud Run (API) — saída apenas para ranges privados
      → VPC Connector
          → Cloud SQL  (subnet 10.0.1.0/24 — sem IP público)
          → Redis       (subnet 10.0.2.0/24 — sem IP público)
```

---

## 6. Conformidade Regulatória (CVM / ANBIMA / LGPD) 🔴 Crítico

### Trilha de Auditoria Imutável

```sql
CREATE TABLE audit_log (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id),
    event_type      TEXT NOT NULL,
    module          TEXT,
    input_snapshot  JSONB NOT NULL,
    result_snapshot JSONB NOT NULL,
    ip_address      INET,
    user_agent      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
REVOKE UPDATE, DELETE ON audit_log FROM investefacil_app;
```

Log gravado assincronamente — não bloqueia a resposta ao cliente.

### LGPD — Anonimização no Ranking

Já implementado: `pseudonymFromID()` → "Investidor_XXXX". Determinístico mas irreversível sem o UUID original.

### Suitability — Persistência no Banco 🟡 Média

Hoje o perfil de suitability fica apenas em `localStorage` do usuário. Para compliance ANBIMA (expiração em 24 meses) deve ser persistido no banco com timestamp e renovado periodicamente.

### Disclaimer Regulatório

Campo `aviso` já presente nas respostas de renda variável. Deve ser exibido de forma proeminente e incluir:

> "As simulações têm caráter meramente informativo e educacional. Rentabilidade passada não é garantia de rentabilidade futura. Esta plataforma não constitui consultoria de valores mobiliários nos termos da Resolução CVM 19/2021."

---

## 7. Pipeline CI/CD (GitHub Actions) 🟠 Alta

```yaml
on:
  push:
    branches: [main]
jobs:
  deploy:
    steps:
      - uses: google-github-actions/auth@v2
      - name: Build and push image
        run: docker build -t gcr.io/$PROJECT_ID/investefacil:$GITHUB_SHA .
      - name: Deploy sem tráfego (blue/green)
        run: gcloud run deploy investefacil-api --image ... --no-traffic
      - name: Smoke test
        run: curl -f $URL/healthz
      - name: Migrar tráfego
        run: gcloud run services update-traffic investefacil-api --to-latest
```

---

## Resumo de Prioridades

| Prioridade | Item | Complexidade | Impacto |
|---|---|---|---|
| ✅ Feito | Logs estruturados JSON (slog) | — | Observabilidade |
| ✅ Feito | Métricas Prometheus | — | Observabilidade |
| ✅ Feito | Gamificação (badges, ranking, reset) | — | Engajamento |
| ✅ Feito | Error boundaries + WebVitals frontend | — | Observabilidade frontend |
| 🔴 Crítico | Audit log imutável | Média | Compliance CVM |
| 🔴 Crítico | GCP Secret Manager (remover .env) | Baixa | Segurança |
| 🔴 Crítico | TLS + HTTPS no Load Balancer | Baixa | Segurança |
| 🟠 Alta | Redis para cache distribuído de taxas | Média | Escalabilidade |
| 🟠 Alta | Integração Brapi (preços reais de ações) | Alta | Confiabilidade dos dados |
| 🟠 Alta | CI/CD com blue/green deploy | Média | Confiabilidade de deploy |
| 🟡 Média | Isolamento VPC (SQL + Redis sem IP público) | Média | Segurança |
| 🟡 Média | Health check com dependências | Baixa | Resiliência |
| 🟡 Média | Rate limiting por IP (hoje: token bucket global) | Média | Proteção DoS |
| 🟡 Média | Suitability persistido no banco | Alta | Compliance ANBIMA |
| 🟢 Baixa | CMEK para campos pessoais (Cloud KMS) | Alta | Segurança avançada |
| 🟢 Baixa | Cloud Monitoring + alertas Prometheus | Média | Observabilidade avançada |

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

Valores aproximados — mai/2026. Criar alerta de orçamento com `gcloud billing budgets create` antes do go-live.
