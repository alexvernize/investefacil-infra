# investefacil-infra

Repositório centralizador da infraestrutura do ecossistema **Investefácil**.
Orquestra o backend Go e o frontend Next.js localmente via Docker Compose e
provisiona a infraestrutura em nuvem (AWS sa-east-1) via Terraform.

## Estrutura

```
investefacil-infra/
├── docker-compose.yml      ← orquestração local (builds apontam para repos irmãos)
├── .env.example            ← template de variáveis — copiar para .env antes de subir
├── terraform/              ← infraestrutura AWS (VPC, subnets, security groups)
└── scripts/
    └── bootstrap.sh        ← cria bucket S3 + tabela DynamoDB para state remoto
```

**Repositórios de aplicação:**

| Repo | Descrição |
|------|-----------|
| [`investefacil`](https://github.com/alexvernize/investefacil) | API Go (renda fixa + renda variável) |
| [`investefacil-front`](https://github.com/alexvernize/investefacil-front) | Frontend Next.js |

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
```

O `.env` padrão funciona para desenvolvimento local sem nenhuma edição adicional.

---

### Subir o ambiente completo

```bash
docker compose up -d --build
```

O flag `--build` reconstrói as imagens a partir do código-fonte dos repos irmãos.
Omita-o nas próximas subidas se o código não mudou.

O frontend só sobe após o backend passar o healthcheck (`/healthz`).

### Verificar saúde dos serviços

```bash
# Status resumido dos containers
docker compose ps

# Logs em tempo real de todos os serviços
docker compose logs -f

# Logs de um serviço específico
docker compose logs -f backend
docker compose logs -f frontend
```

Endpoints disponíveis após a subida:

| Serviço | URL |
|---------|-----|
| Frontend | http://localhost:3000 |
| Backend API | http://localhost:8080 |
| Health check | http://localhost:8080/healthz |

### Derrubar o ambiente

```bash
# Para os containers e remove redes (preserva volumes)
docker compose down

# Para, remove containers, redes e volumes (reset completo)
docker compose down -v
```

### Rebuild de um único serviço

```bash
# Após alterar código no backend
docker compose up -d --build backend

# Após alterar código no frontend
docker compose up -d --build frontend
```

---

### Validação local antes do push

Execute antes de abrir um PR para garantir que o CI não vai falhar:

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

**Docker (Hadolint):**
```bash
docker run --rm -i hadolint/hadolint < ../investefacil/Dockerfile
docker run --rm -i hadolint/hadolint < ../investefacil-front/Dockerfile
```

---

## Infraestrutura AWS (Terraform)

### Bootstrap — rodar uma única vez por conta AWS

Cria o bucket S3 e a tabela DynamoDB que armazenam o state remoto.
Requer AWS CLI autenticado com permissões de administrador.

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

Consulte o `CLAUDE.md` para detalhes completos sobre variáveis, módulos e
convenções de nomenclatura de recursos.
