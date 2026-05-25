# Makefile — orquestração local do ecossistema investefácil (Docker Compose).
#
# Resolve o conflito de container_name fixo ("container name already in use"):
# antes de subir, remove à força qualquer container com os nomes do projeto,
# mesmo que tenham sido criados por outro contexto/compose. O `docker compose
# down` do projeto infra não remove um container pertencente a outro projeto —
# por isso o `docker rm -f` por nome.
#
# Uso típico:
#   make start   # rebuild total sem cache + sobe + aplica migrations
#   make back    # rebuild sem cache só do backend
#   make front   # rebuild sem cache só do frontend

COMPOSE        := docker compose
DB_USER        := investefacil
DB_NAME        := investefacil
CONTAINERS     := investefacil-db investefacil-api investefacil-front
MIGRATIONS_DIR := /docker-entrypoint-initdb.d

.PHONY: start up down clean back front migrate reset rebuild logs ps help

## start: limpa conflitos, rebuilda tudo sem cache, sobe e aplica as migrations
start: clean
	$(COMPOSE) build --no-cache
	$(COMPOSE) up -d
	$(MAKE) migrate

## up: sobe os serviços sem rebuildar
up:
	$(COMPOSE) up -d

## down: derruba o stack e remove órfãos (preserva o volume do banco)
down:
	-$(COMPOSE) down --remove-orphans

## clean: down + remoção forçada dos containers pelo nome (elimina o conflito)
clean: down
	-docker rm -f $(CONTAINERS) 2>/dev/null
	@true

## back: rebuild SEM cache apenas do backend e recria só ele (stack já no ar)
back:
	-docker rm -f investefacil-api
	$(COMPOSE) build --no-cache backend
	$(COMPOSE) up -d --no-deps backend

## front: rebuild SEM cache apenas do frontend e recria só ele (stack já no ar)
front:
	-docker rm -f investefacil-front
	$(COMPOSE) build --no-cache frontend
	$(COMPOSE) up -d --no-deps frontend

## migrate: aplica todas as migrations (idempotentes) no Postgres em execução
migrate:
	@echo "Aguardando o PostgreSQL ficar pronto..."
	@until $(COMPOSE) exec -T postgres pg_isready -U $(DB_USER) -d $(DB_NAME) >/dev/null 2>&1; do sleep 1; done
	@echo "Aplicando migrations..."
	@$(COMPOSE) exec -T postgres sh -c 'for f in $(MIGRATIONS_DIR)/*.sql; do echo "  -> $$f"; psql -v ON_ERROR_STOP=1 -U $(DB_USER) -d $(DB_NAME) -f "$$f" >/dev/null || exit 1; done'
	@echo "Migrations aplicadas."

## reset: APAGA o volume do banco e sobe do zero (migrations rodam no init)
reset: clean
	-$(COMPOSE) down -v
	$(COMPOSE) build --no-cache
	$(COMPOSE) up -d

## rebuild: rebuild sem cache de tudo, sem apagar o banco (não roda migrate)
rebuild: clean
	$(COMPOSE) build --no-cache
	$(COMPOSE) up -d

## logs: segue os logs de todos os serviços
logs:
	$(COMPOSE) logs -f

## ps: status dos containers
ps:
	$(COMPOSE) ps

## help: lista os alvos disponíveis
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //'
