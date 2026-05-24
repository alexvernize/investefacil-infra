# EXPANSION_ROADMAP — Arquitetura de Expansão Tecnológica

Plano técnico e contratos de arquitetura para a próxima grande expansão da plataforma
**Investefácil**: o Explorador de Passado, o Mentor Virtual com IA e a arquitetura Mobile.

**Estado atual (base):** API Go com simuladores stateless + Carteira Virtual PostgreSQL + Frontend
Next.js 16 + logs JSON + métricas Prometheus.

---

## 1. Explorador de Passado — "Volta no Tempo"

> *"E se eu tivesse investido R$ 7.000 em WEGE3 em 2023 em vez de comprar um celular?"*

### Conceito

O usuário escolhe um ativo, um valor e uma data de início no passado. O motor calcula — com
dados históricos reais — quanto esse investimento valeria hoje, incluindo dividendos recebidos,
splits e agrupamentos. O contraste entre "o que comprei" e "o que teria rendido" é o gatilho
emocional que transforma comportamento financeiro.

### Arquitetura do motor Go (`internal/timemachine/`)

```
internal/
  timemachine/
    domain.go       ← tipos: TimeMachineInput, TimeMachineResult
    engine.go       ← Simulate(input, provider) — lógica pura, sem I/O
    provider.go     ← interface HistoricalProvider
```

#### Contrato de entrada e saída

```go
// domain.go

type TimeMachineInput struct {
    Ticker      string    // "WEGE3"
    StartDate   time.Time // data de compra hipotética
    EndDate     time.Time // default: hoje
    Amount      float64   // valor investido em reais
}

type TimeMachineResult struct {
    Ticker          string
    Nome            string
    StartDate       time.Time
    EndDate         time.Time
    Months          int
    PriceAtPurchase float64   // preço histórico na data de compra
    PriceToday      float64   // preço atual
    Shares          int       // floor(Amount / PriceAtPurchase)
    AmountInvested  float64   // Shares × PriceAtPurchase (valor real investido)
    CapitalToday    float64   // Shares × PriceToday
    CapitalGain     float64   // CapitalToday − AmountInvested
    TotalDividends  float64   // soma de proventos no período
    FinalValue      float64   // CapitalToday + TotalDividends
    TotalReturn     float64   // % sobre AmountInvested
    // Para o contraste "E se...":
    AlternativeName    string  // ex: "celular novo"
    AlternativeValue   float64 // valor atual do bem comprado (depreciado)
    OpportunityCost    float64 // FinalValue − AlternativeValue
}
```

#### Motor de cálculo (`engine.go`)

```go
func Simulate(ctx context.Context, input TimeMachineInput, p HistoricalProvider) (TimeMachineResult, error) {
    // 1. Buscar série de preços mensais entre StartDate e EndDate
    prices, err := p.FetchPriceRange(ctx, input.Ticker, input.StartDate, input.EndDate)
    // prices[0] = preço em StartDate; prices[len-1] = preço em EndDate

    // 2. Calcular cotas compráveis (inteiras — sem fração de ação)
    shares := int(math.Floor(input.Amount / prices[0]))
    if shares == 0 {
        return TimeMachineResult{}, ErrCapitalInsuficiente
    }

    // 3. Buscar proventos pagos no período
    dividends, err := p.FetchDividends(ctx, input.Ticker, input.StartDate, input.EndDate)
    totalDividends := 0.0
    for _, d := range dividends {
        totalDividends += d.AmountPerShare * float64(shares)
    }

    // 4. Montar resultado
    amountInvested := float64(shares) * prices[0]
    capitalToday   := float64(shares) * prices[len(prices)-1]
    finalValue      := capitalToday + totalDividends
    return TimeMachineResult{
        AmountInvested: amountInvested,
        CapitalToday:   capitalToday,
        TotalDividends: totalDividends,
        FinalValue:     finalValue,
        TotalReturn:    (finalValue/amountInvested - 1) * 100,
        // OpportunityCost calculado pelo handler com base na "alternativa" fornecida
    }, nil
}
```

#### Interface do provedor de dados históricos

```go
// provider.go
type HistoricalProvider interface {
    // Série de preços mensais de fechamento ajustados (splits incluídos)
    FetchPriceRange(ctx context.Context, ticker string, from, to time.Time) ([]float64, error)
    // Proventos pagos no período (dividendos + JCP)
    FetchDividends(ctx context.Context, ticker string, from, to time.Time) ([]Dividend, error)
}

type Dividend struct {
    PaymentDate   time.Time
    AmountPerShare float64
}

// Implementações:
// MockProvider     → dados estáticos para testes e dev
// BrapiProvider    → dados reais via brapi.dev (cache Redis 24h)
// B3HistoricalDB   → tabela própria no PostgreSQL (para amplitude > 3 anos)
```

### Tabela de dados históricos no PostgreSQL

Para séries longas (> 3 anos) e consultas frequentes, manter tabela própria alimentada por um
job periódico (cron diário):

```sql
CREATE TABLE stock_prices (
    ticker      VARCHAR(6)  NOT NULL,
    price_date  DATE        NOT NULL,
    close_price NUMERIC(12,4) NOT NULL,  -- preço ajustado por splits
    PRIMARY KEY (ticker, price_date)
);

CREATE TABLE stock_dividends (
    ticker          VARCHAR(6)    NOT NULL,
    payment_date    DATE          NOT NULL,
    amount_per_share NUMERIC(10,6) NOT NULL,
    type             VARCHAR(10)   NOT NULL  -- 'DIVIDEND' | 'JCP'
);

CREATE INDEX idx_stock_prices_ticker_date ON stock_prices(ticker, price_date DESC);
CREATE INDEX idx_stock_dividends_ticker   ON stock_dividends(ticker, payment_date DESC);
```

**Job de ingestão diária (Go ou Python):**

```
cron 18:30 BRT → HTTP GET brapi.dev/api/v2/history?ticker=WEGE3&range=1mo&interval=1d
  → upsert em stock_prices (ON CONFLICT DO UPDATE)
  → HTTP GET brapi.dev/api/v2/dividends?ticker=WEGE3
  → upsert em stock_dividends
```

### Endpoint da API

```
GET /api/v1/timemachine?ticker=WEGE3&startDate=2023-01-15&amount=7000&alternativeValue=4500
```

Response:
```json
{
  "ticker": "WEGE3",
  "nome": "WEG ON",
  "startDate": "2023-01-15",
  "endDate": "2026-05-24",
  "months": 40,
  "priceAtPurchase": 35.20,
  "priceToday": 52.80,
  "shares": 198,
  "amountInvested": 6969.60,
  "capitalToday": 10454.40,
  "totalDividends": 594.00,
  "finalValue": 11048.40,
  "totalReturn": 58.52,
  "alternativeName": "celular",
  "alternativeValue": 4500.00,
  "opportunityCost": 6548.40,
  "message": "Investindo R$ 7.000 em WEGE3 em jan/2023 em vez de comprar o celular, você teria R$ 11.048 hoje — R$ 6.548 a mais que o valor atual do aparelho."
}
```

### Fluxo completo de uma requisição

```
Frontend (React)
  → GET /api/v1/timemachine?ticker=WEGE3&startDate=2023-01-15&amount=7000
      → timemachine.Handler
          → parse e validar parâmetros (startDate ≤ hoje − 1 mês, amount > 0)
          → provider.FetchPriceRange(ctx, "WEGE3", 2023-01-15, hoje)
              → RedisCache.Get("prices:WEGE3:2023-01-15:2026-05-24")
                  HIT  → retornar do cache
                  MISS → PostgreSQL stock_prices → armazenar no Redis (TTL 24h)
          → provider.FetchDividends(ctx, "WEGE3", 2023-01-15, hoje)
              → PostgreSQL stock_dividends
          → engine.Simulate(input, provider)
          → json.Encode(TimeMachineResult)
      → 200 OK + JSON
```

---

## 2. Mentor Virtual — Análise de Carteira via IA

> O usuário envia sua carteira para um modelo de linguagem e recebe uma análise educativa de
> diversificação, sem recomendações diretas de compra (compliance CVM).

### Princípio de Segurança: Zero PII para a IA

Antes de qualquer chamada ao LLM, o backend **anonimiza** o snapshot da carteira. O modelo
de IA nunca recebe UUID, nome de usuário, e-mail ou qualquer identificador pessoal.

### Contrato do snapshot anonimizado

```go
// internal/mentor/anonymizer.go

type PortfolioSnapshot struct {
    // NUNCA incluir: user_id, wallet_id, name, email
    TotalValue    float64         `json:"totalValue"`    // saldo total atual
    Positions     []Position      `json:"positions"`
    SectorWeights map[string]float64 `json:"sectorWeights"` // calculado no backend
}

type Position struct {
    Ticker  string  `json:"ticker"`  // ex: "PETR3" — ticker é público, não PII
    Sector  string  `json:"sector"`
    Shares  int     `json:"shares"`
    CurrentValue float64 `json:"currentValue"`
    WeightPct    float64 `json:"weightPct"`   // % do portfólio
}

// Antes de enviar ao LLM: arredondar valores para reduzir rastreabilidade
// (ex: R$ 9.847,32 → R$ 9.800 — remove informação de precisão sem perder sentido analítico)
func Anonymize(snapshot PortfolioSnapshot) PortfolioSnapshot {
    snapshot.TotalValue = math.Round(snapshot.TotalValue/100) * 100
    for i := range snapshot.Positions {
        snapshot.Positions[i].CurrentValue = math.Round(snapshot.Positions[i].CurrentValue/10) * 10
    }
    return snapshot
}
```

### System Prompt para análise de diversificação

O prompt abaixo equilibra utilidade educativa com compliance CVM (Resolução CVM 19/2021 —
proibição de consultoria não habilitada) e ANBIMA.

```
Você é o Mentor Virtual do InvesteFácil, um assistente educativo sobre investimentos para
pessoas que estão aprendendo a investir. Sua função é ANALISAR e EDUCAR — nunca recomendar
compra ou venda de ativos específicos.

REGRAS DE COMPLIANCE (não negociáveis):
1. Nunca use as palavras "compre", "venda", "invista em", "recomendo" ou equivalentes.
2. Nunca afirme que um ativo vai subir ou descer de preço.
3. Se o usuário perguntar "devo comprar X?", responda: "Não tenho habilitação para recomendar
   ativos. Consulte um assessor de investimentos certificado pela ANCORD ou CGA/CFP pela ANBIMA."
4. Sempre inclua ao final: "Esta análise é educativa e não constitui consultoria de valores
   mobiliários conforme a Resolução CVM 19/2021."

SEU PAPEL:
- Identificar CONCENTRAÇÃO EXCESSIVA: quando um único ativo representa > 40% do portfólio,
  alertar que concentração alta aumenta o risco não-sistemático (risco específico da empresa).
- Identificar CONCENTRAÇÃO SETORIAL: quando um setor representa > 50% do portfólio, explicar
  que eventos setoriais (regulação, commodities, juros) afetam todas as posições juntas.
- Explicar o conceito de CORRELAÇÃO de forma simples: "Quando todas as suas ações são de bancos,
  elas tendem a cair juntas se o Banco Central subir os juros."
- Destacar AUSÊNCIA DE RENDA FIXA se o portfólio for 100% renda variável: explicar o papel da
  diversificação entre classes de ativos, sem recomendar produtos específicos.
- Usar linguagem de 5ª série: sem jargão não explicado. Todo termo técnico deve vir com
  definição entre parênteses na primeira menção.
- Ser encorajador: o objetivo é que o usuário continue aprendendo, não que se sinta criticado.

FORMATO DA RESPOSTA:
1. Resumo em 2 frases do estado atual da carteira.
2. Pontos de atenção (máx. 3 bullets — focar nos mais relevantes).
3. Conceito educativo do dia (1 parágrafo curto relacionado à carteira analisada).
4. Disclaimer de compliance.

DADOS DA CARTEIRA (JSON):
{{PORTFOLIO_JSON}}
```

### Arquitetura do serviço de Mentor (`internal/mentor/`)

```
internal/mentor/
  domain.go       ← PortfolioSnapshot, Position, MentorRequest, MentorResponse
  anonymizer.go   ← Anonymize(): remove PII, arredonda valores
  prompt.go       ← BuildPrompt(snapshot): injeta JSON no system prompt
  llm_client.go   ← interface LLMClient + AnthropicClient + OpenAIClient
  handler.go      ← POST /api/v1/mentor/analyze
```

#### Interface do cliente LLM (agnóstica ao provedor)

```go
// llm_client.go
type LLMClient interface {
    Analyze(ctx context.Context, systemPrompt, userMessage string) (string, error)
}

type AnthropicClient struct {
    apiKey  string
    model   string        // "claude-sonnet-4-6" (default); configurável por env var
    maxTokens int         // default: 800 — resposta concisa para mobile
    httpClient *http.Client
}

func (c *AnthropicClient) Analyze(ctx context.Context, systemPrompt, userMessage string) (string, error) {
    payload := map[string]any{
        "model":      c.model,
        "max_tokens": c.maxTokens,
        "system":     systemPrompt,
        "messages":   []map[string]string{{"role": "user", "content": userMessage}},
    }
    // POST https://api.anthropic.com/v1/messages
    // Header: x-api-key, anthropic-version: "2023-06-01"
    // Retornar content[0].text
}
```

#### Fluxo seguro de uma análise

```
POST /api/v1/mentor/analyze  { walletId: "uuid" }
  → Autenticar usuário (session token)
  → SELECT posições da carteira WHERE wallet_id = $1     ← só da carteira do usuário logado
  → anonymizer.Anonymize(snapshot)                       ← remove PII, arredonda valores
  → mentor.BuildPrompt(anonymized)                       ← injeta JSON no system prompt
  → LLMClient.Analyze(ctx, systemPrompt, "Analise esta carteira")
      → POST api.anthropic.com/v1/messages
          → Claude retorna análise em texto
  → Salvar análise no audit_log (event_type: "mentor_analysis")
  → json.Encode(MentorResponse{ analysis: "..." })
  → 200 OK
```

#### Variáveis de ambiente necessárias

| Variável | Descrição |
|---|---|
| `ANTHROPIC_API_KEY` | Chave da API Anthropic (via Secret Manager em produção) |
| `MENTOR_MODEL` | Modelo a usar (default: `claude-sonnet-4-6`) |
| `MENTOR_MAX_TOKENS` | Limite de tokens da resposta (default: `800`) |
| `MENTOR_ENABLED` | Feature flag — `true`/`false`; desabilita sem redeploy |

#### Proteções de custo e rate limit

```go
// Limite de análises por carteira para controlar custo da API de IA
// Redis: incrementar contador daily por wallet_id; bloquear se > MAX_ANALYSES_PER_DAY
const MaxAnalysesPerDay = 5  // configurável via env var

func (h *MentorHandler) checkRateLimit(ctx context.Context, walletID string) error {
    key := fmt.Sprintf("mentor:daily:%s:%s", walletID, time.Now().Format("2006-01-02"))
    count, _ := h.redis.Incr(ctx, key).Result()
    h.redis.Expire(ctx, key, 25*time.Hour)  // TTL 25h garante reset diário
    if count > MaxAnalysesPerDay {
        return ErrMentorRateLimitExceeded
    }
    return nil
}
```

---

## 3. Arquitetura Mobile — Gatilhos de Dopamina

### 3.1 Notificações Push de Proventos

O objetivo é notificar o usuário quando uma empresa da sua carteira paga dividendos — mesmo que
o valor seja fictício (simulação). A sensação de receber "dinheiro na conta" é o gatilho de
engajamento mais poderoso em aplicativos financeiros.

#### Fluxo de mensageria

```
Agenda B3 (fonte de dados)
  ↓ cron job diário 07:00 BRT
Job de Proventos (Go)
  ↓ SELECT posições por ticker com data_com hoje
  ↓ PARA CADA usuário com posição:
      INSERT INTO notifications (user_id, type, payload, scheduled_at)
  ↓
Notification Worker (Go — goroutine pool)
  ↓ SELECT * FROM notifications WHERE scheduled_at <= NOW() AND sent_at IS NULL
  ↓ PARA CADA notificação:
      → HTTP POST para FCM (Firebase Cloud Messaging)   ← Android + iOS
      → UPDATE notifications SET sent_at = NOW()
```

#### Schema de notificações

```sql
CREATE TABLE notifications (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID        NOT NULL REFERENCES users(id),
    type         TEXT        NOT NULL,  -- 'dividend_received' | 'price_alert' | 'badge_unlocked'
    title        TEXT        NOT NULL,
    body         TEXT        NOT NULL,
    payload      JSONB,                 -- dados extras para deep link (ticker, valor)
    scheduled_at TIMESTAMPTZ NOT NULL,
    sent_at      TIMESTAMPTZ,
    fcm_token    TEXT        NOT NULL,  -- device token do Firebase
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_notifications_pending ON notifications(scheduled_at)
    WHERE sent_at IS NULL;
```

#### Payload de notificação de provento

```json
{
  "title": "💰 WEGE3 pagou dividendos!",
  "body": "Sua posição em WEG ON recebeu R$ 47,52 em proventos. Confira na sua carteira.",
  "data": {
    "type": "dividend_received",
    "ticker": "WEGE3",
    "amount": 47.52,
    "deepLink": "investefacil://wallet/transactions"
  }
}
```

#### Cliente FCM (Go)

```go
// internal/notifications/fcm_client.go
type FCMClient struct {
    projectID  string
    httpClient *http.Client
    tokenCache *oauth2.Token  // service account token, renovado automaticamente
}

func (c *FCMClient) Send(ctx context.Context, fcmToken, title, body string, data map[string]string) error {
    msg := map[string]any{
        "message": map[string]any{
            "token": fcmToken,
            "notification": map[string]string{"title": title, "body": body},
            "data": data,
            "android": map[string]any{
                "priority": "high",
                "notification": map[string]string{
                    "channel_id": "dividends",
                    "sound": "default",
                },
            },
            "apns": map[string]any{
                "payload": map[string]any{
                    "aps": map[string]any{
                        "sound": "default",
                        "badge": 1,
                    },
                },
            },
        },
    }
    // POST https://fcm.googleapis.com/v1/projects/{projectID}/messages:send
    // Authorization: Bearer {service_account_token}
}
```

#### Agenda de Proventos da B3 — fonte de dados

A B3 publica o calendário de dividendos via portal público e provedores como a Brapi:

```
GET https://brapi.dev/api/v2/dividends?ticker=WEGE3
```

Response inclui `declarationDate`, `recordDate` (data-com), `paymentDate` e `rate` (valor por cota).

**Job de sincronização da agenda** (Go, executado 1× por dia):
1. Para cada ticker no universo da plataforma, buscar dividendos com `paymentDate` nos próximos 7 dias.
2. Para cada dividendo, buscar carteiras com posição no ticker (`SELECT wallet_id, shares FROM transactions WHERE ticker = $1`).
3. Calcular `amount = shares × rate`.
4. INSERT em `notifications` com `scheduled_at = paymentDate 09:00 BRT`.

---

### 3.2 Microsserviço de OCR para Notas de Corretagem

O objetivo futuro é que o usuário fotografe ou faça upload do PDF de nota de corretagem e o
sistema cadastre as transações automaticamente, eliminando entrada manual.

#### Arquitetura do microsserviço

```
investefacil-ocr/          ← repositório separado (Python ou Go)
  src/
    parser/
      base.py              ← classe abstrata NoteParser
      xp.py                ← XP Investimentos (PDF estruturado)
      inter.py             ← Banco Inter (PDF + HTML)
      nuinvest.py          ← NuInvest (PDF)
      generic.py           ← fallback: extração por regex genérica
    ocr/
      extractor.py         ← PyMuPDF (fitz) para extração de texto de PDF
      image_fallback.py    ← Tesseract OCR para PDFs digitalizados (imagem)
    api/
      routes.py            ← POST /parse-note (FastAPI)
    models.py              ← ParsedNote, ParsedTransaction
```

#### Fluxo de parsing de uma nota XP

```
Upload do PDF (multipart/form-data)
  → extractor.extract_text(pdf_bytes)
      → PyMuPDF fitz.open()  ← extrai texto nativo do PDF
      → se texto vazio → Tesseract OCR (PDF escaneado)
  → broker_detector.detect(text)
      → regex por padrões de cabeçalho: "XP INVESTIMENTOS", "INTER DTVM", "NU INVEST"
  → parser = XPParser() | InterParser() | NuInvestParser() | GenericParser()
  → parser.parse(text)
      → extrair: data_pregão, ticker, quantidade, preço, tipo (C/V), taxas
  → ParsedNote
```

#### Campos extraídos de uma nota de corretagem

```python
# models.py
@dataclass
class ParsedTransaction:
    date: str           # "2026-05-24"
    ticker: str         # "PETR3"
    operation: str      # "BUY" | "SELL"
    quantity: int       # 100
    unit_price: float   # 38.20
    total_gross: float  # 3820.00
    brokerage_fee: float  # 4.90
    total_net: float    # 3824.90

@dataclass
class ParsedNote:
    broker: str                        # "XP" | "INTER" | "NUINVEST" | "UNKNOWN"
    trade_date: str                    # data do pregão
    transactions: list[ParsedTransaction]
    confidence: float                  # 0.0–1.0 — qualidade do parsing
    raw_text: str                      # texto bruto para auditoria
    warnings: list[str]                # alertas de campos não encontrados
```

#### Endpoint do microsserviço

```
POST /parse-note
Content-Type: multipart/form-data
Body: { file: <PDF binary>, broker_hint: "XP" }  ← broker_hint é opcional

Response 200:
{
  "broker": "XP",
  "tradeDate": "2026-05-24",
  "confidence": 0.97,
  "transactions": [
    {
      "date": "2026-05-24",
      "ticker": "PETR3",
      "operation": "BUY",
      "quantity": 100,
      "unitPrice": 38.20,
      "totalGross": 3820.00,
      "brokerageFee": 4.90,
      "totalNet": 3824.90
    }
  ],
  "warnings": []
}
```

#### Integração com o backend Go

```
Frontend mobile
  → POST /api/v1/notes/upload { file: PDF }
      → Go handler (proxy seguro):
          → validar: content-type = application/pdf, tamanho ≤ 5 MB
          → POST investefacil-ocr:8000/parse-note (rede interna VPC)
          → receber ParsedNote
          → exibir transações para CONFIRMAÇÃO do usuário (nunca cadastrar automático sem review)
          → usuário confirma → POST /api/v1/transactions para cada item
```

**Princípio de segurança:** o OCR nunca cadastra transações automaticamente. O usuário revisa e
confirma cada item antes da inserção — evita erros de parsing silenciosos em dados financeiros.

#### Padrões de parsing por corretora (exemplos)

| Campo | XP Investimentos | Banco Inter | NuInvest |
|---|---|---|---|
| Data pregão | `"Data pregão: DD/MM/AAAA"` | `"Data Negócio: DD/MM/AAAA"` | `"DATA NEGÓCIO DD/MM/AAAA"` |
| Ticker | 4ª coluna da tabela de negócios | Coluna "Ativo" | Coluna "Papel" |
| Quantidade | Coluna "Qtde" ou "Quantidade" | Coluna "Qtde" | Coluna "Qtde." |
| Preço | Coluna "Preço" (R$ com vírgula decimal) | Coluna "Preço/Ajuste" | Coluna "Preço (R$)" |
| Tipo C/V | Coluna "C/V" ou "Tipo operação" | Coluna "Tipo Operação" | "C" ou "V" inline |

**Nota:** layouts de PDF mudam a cada atualização das corretoras. O parser precisa de testes de
regressão com PDFs reais de cada versão de layout. Manter um conjunto de fixtures anonimizadas
no repositório para CI.

---

## Resumo de Dependências e Sequenciamento

```
Fase 1 — Base de dados históricos (prerequisito para tudo)
  → Criar tabelas stock_prices + stock_dividends
  → Implementar job de ingestão via Brapi
  → Criar BrapiProvider implementando HistoricalProvider

Fase 2 — Explorador de Passado
  → internal/timemachine/: domain, engine, provider, handler
  → Endpoint GET /api/v1/timemachine
  → Frontend: nova rota /explorador com seletor de data + ativo

Fase 3 — Mentor Virtual
  → Configurar Anthropic API Key no Secret Manager
  → internal/mentor/: anonymizer, prompt, llm_client, handler
  → Endpoint POST /api/v1/mentor/analyze
  → Rate limiter por carteira (Redis)
  → Frontend: botão "Pedir análise do Mentor" na Visão Geral da carteira

Fase 4 — Mobile (React Native ou Flutter)
  → Registrar FCM tokens dos dispositivos
  → Criar tabela notifications
  → Job de sincronização da agenda de proventos B3
  → Notification Worker (goroutine pool)

Fase 5 — OCR (repositório separado)
  → investefacil-ocr (Python/FastAPI)
  → Parser por corretora com fixtures de teste
  → Integração com backend Go via VPC interna
  → UI de revisão de transações antes de confirmar
```

---

## Estimativa de Custo Adicional (GCP)

| Serviço | Item | Estimativa mensal |
|---|---|---|
| Anthropic API | Claude Sonnet 4.6 — ~1.000 análises/mês × ~800 tokens output | ~USD 15–25 |
| Cloud Run extra | Serviço OCR (Python) — baixa concorrência | ~USD 5–15 |
| Firebase FCM | Push notifications | Gratuito (até 1M/mês) |
| Cloud Storage | PDFs de notas de corretagem (30 dias, depois deletar) | ~USD 1–2 |
| BigQuery (futuro) | Analytics de comportamento de usuário | ~USD 0 (free tier) |
| **Total adicional** | | **~USD 21–42/mês** |

Custo base da plataforma: ~USD 90–110/mês (ver `PRODUCTION_READY.md`).
**Total estimado com expansão completa: ~USD 110–150/mês.**
