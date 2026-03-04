# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo is a homelab automation toolkit for provisioning Raspberry Pi hosts and deploying Docker-based services to them. Scripts run from an admin workstation (macBook) and drive all steps on target hosts via SSH. Secrets are managed via 1Password and fetched at deploy time — never committed.

Primary artifacts: `provision.sh`, `gen-spec.sh`, `provision-host.sh`, `provision-service.sh`, `common/lib.sh`, `common/gen-env.sh`, and service definitions under `services/`.

## Repository structure

```
├── provision.sh             # Orchestrator: provision hosts/services from servers.yaml
├── gen-spec.sh              # Generate servers.yaml from 1Password server.* items
├── provision-host.sh        # Prepare a bare host: OS updates, Docker, 1Password CLI, repo clone
├── provision-service.sh     # Deploy a service: gen .env from 1Password, docker compose up
├── servers.example.yaml     # Documented example provisioning spec
├── common/
│   ├── lib.sh               # Shared functions: log(), die(), vault_for_env()
│   └── gen-env.sh           # Fetch 1Password item, emit env. fields as NAME=value
└── services/
    └── n8n/
        ├── docker-compose.yml
        └── .env.example
```

## n8n service stack

Three Docker Compose services (defined in `services/n8n/docker-compose.yml`):
- **n8n** (`n8nio/n8n`) — workflow automation, exposed on port 5678
- **postgres** (`postgres:16-alpine`) — database backend, bind-mounted to `/opt/n8n/postgres`, UID/GID 70:70
- **n8n-runners** (`n8nio/runners`) — external task runner, connects to n8n's broker on port 5679

n8n waits for postgres via a `healthcheck` / `depends_on` condition before starting.

## Operations

### Provisioning (from macBook)

```bash
# Generate (or regenerate) servers.yaml from 1Password
./provision.sh --generate
./provision.sh --generate --spec myservers.yaml

# Provision a server (auto-generates servers.yaml if it doesn't exist)
./provision.sh rpicm5b                        # full: host + services
./provision.sh rpicm5b --host-only            # host provisioning only
./provision.sh rpicm5b --services-only        # service deployments only
./provision.sh rpicm5b dev                    # override env (default: from servers.yaml)
./provision.sh rpicm5b --spec myservers.yaml  # use a named spec file

# Or provision a single host/service directly
./provision-host.sh --env dev --host rpicm5b
./provision-service.sh --env dev --host rpicm5b --service n8n
```

### n8n stack lifecycle (on host at /opt/n8n/services/n8n)

```bash
docker compose up -d
docker compose down
docker compose ps
docker compose logs -f n8n
docker compose logs -f postgres

# Database backup
docker exec -t n8n-postgres pg_dump -U n8n -d n8n | gzip > /opt/n8n/backups/n8n-$(date +%F).sql.gz

# Database restore
gunzip -c /opt/n8n/backups/n8n-YYYY-MM-DD.sql.gz | docker exec -i n8n-postgres psql -U n8n -d n8n
```

## Key constraints

- `setup.sh` enforces that it runs as root (`sudo`) and only from `/opt/n8n`. It is safe to re-run.
- `N8N_ENCRYPTION_KEY` must never change once set — changing it breaks all stored credentials in the DB.
- `.env` is never committed. Secrets are copy/pasted manually from 1Password.
- `service.n8n.json` and `vaults.lst` are 1Password-related files — they may contain sensitive values and must not be committed.
- Postgres data dir (`/opt/n8n/postgres`) is created and owned by postgres (uid 70, gid 0) on first start — do not pre-create it.
- `/home/ops/.op_env` on each host contains the OP service account token (mode 600). Placed by `provision-host.sh` Phase 5b; sourced by `provision-service.sh` at deploy time. Never committed.

## 1Password conventions

### Admin workstation prerequisites

- `op` (1Password CLI): `brew install --cask 1password-cli`
- `yq` (YAML processor): `brew install yq`
- `jq` (JSON processor): `brew install jq`

### Vault layout

| Vault    | Purpose                                      |
|----------|----------------------------------------------|
| `Lab`    | Shared items: GitHub SSH key, `server.*` host specs |
| `devLab` | Dev-environment secrets: `op-service-account`, `service.*` items |
| `prodLab`| Prod-environment secrets                     |

### `server.*` items (Lab vault)

One item per host, named `server.<hostname>`. Fields:
- `env` — `dev` or `prod` (required)
- `hostname` — optional; SSH target; defaults to the server name
- `app.<name>` — one **section** per app to deploy (e.g. section `app.n8n`); section existence signals "deploy this app". Fields within the section prefixed `env.*` are reserved for host-specific env overrides (future capability).

## Env vars

All runtime configuration flows through `.env` (sourced by Docker Compose). The template is `.env.example`. Required keys: `N8N_ENCRYPTION_KEY`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `N8N_RUNNERS_AUTH_TOKEN`.

Generate `N8N_RUNNERS_AUTH_TOKEN` with: `openssl rand -base64 24`

## HTTPS transition

When moving from HTTP to HTTPS (e.g. adding Traefik/Caddy): update `N8N_HOST`, `N8N_PROTOCOL`, `WEBHOOK_URL` in `.env`, and remove `N8N_SECURE_COOKIE=false`.

## Open issues/ToDo's

1. ~~YAML-based provisioning spec~~ — Implemented: `provision.sh`, `gen-spec.sh`, `servers.example.yaml`.
2. During apt full-upgrade, an interactive prompt appeared for `/etc/chromium/master_preferences`. Likely fixed by `DEBIAN_FRONTEND=noninteractive` added in Phase 1 — **in abeyance, confirm resolved on next provision run**.
