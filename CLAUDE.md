# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo contains the deployment artifacts for a single-user homelab host server and services provisioning. It is designed to be cloned directly into `/opt/n8n` on the target server. There is no build step — the primary artifacts are `docker-compose.yml`, `setup.sh`, and `.env.example`.

## Stack

Three Docker Compose services:
- **n8n** (`n8nio/n8n`) — workflow automation, exposed on port 5678
- **postgres** (`postgres:16-alpine`) — database backend, bind-mounted to `/opt/n8n/postgres`, UID/GID 70:70
- **n8n-runners** (`n8nio/runners`) — external task runner, connects to n8n's broker on port 5679

n8n waits for postgres via a `healthcheck` / `depends_on` condition before starting.

## Operations (run from `/opt/n8n` on the server)

```bash
# First-time setup (creates dirs, sets permissions, creates .env from template)
sudo ./setup.sh

# Stack lifecycle
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
- Postgres data dir (`/opt/n8n/postgres`) is owned by UID/GID 70:70 with mode 700.

## Env vars

All runtime configuration flows through `.env` (sourced by Docker Compose). The template is `.env.example`. Required keys: `N8N_ENCRYPTION_KEY`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `N8N_RUNNERS_AUTH_TOKEN`.

Generate `N8N_RUNNERS_AUTH_TOKEN` with: `openssl rand -base64 24`

## HTTPS transition

When moving from HTTP to HTTPS (e.g. adding Traefik/Caddy): update `N8N_HOST`, `N8N_PROTOCOL`, `WEBHOOK_URL` in `.env`, and remove `N8N_SECURE_COOKIE=false`.

## Open issues/ToDo's

01. Review the purpose statement and revise to reflect expanded scope
1. Rename the repository to remove reference to n8n
2. Consider adding support for provisioning a host and the service(s) that should run in it by defining the spec in a yanl file.
3. During the first (or very early) host provisioning attempt I got a message about some apt managed app (I think) that was out of date/sync.
   
    ```terminal
    Configuration file '/etc/chromium/master_preferences'
    ==> Modified (by you or by a script) since installation.
    ==> Package distributor has shipped an updated version.
    What would you like to do about it ?  Your options are:
      Y or I  : install the package maintainer's version
      N or O  : keep your currently-installed version
      D     : show the differences between the versions
      Z     : start a shell to examine the situation
    The default action is to keep your current version.
    *** master_preferences (Y/I/N/O/D/Z) [default=N] ? Y
    Installing new version of config file /etc/chromium/master_preferences ...
    ```
5. provision-host.sh phase 5 echo's the Github private ssh key to the terminal.
6. OP vault prodLab needs to be carefully reviewed (by Tim) before using it for provisioning production hosts and services
7. Claude should review changes I made to provision-host.sh
8. reordered phase 3 & 4 and added docker run hello-world to better validate install
9. Added assignment and use of the LAB_VAULT variable for use during github key install and anything else that is environment agnostic. Consider adding a lib function to fetch it.
10. The following sequence of messages was in the terminal. Can they be quieted?

    ```terminal
    debconf: unable to initialize frontend: Dialog
    debconf: (Dialog frontend will not work on a dumb terminal, an emacs shell buffer, or without a controlling terminal.)
    debconf: falling back to frontend: Readline
    debconf: unable to initialize frontend: Readline
    debconf: (This frontend requires a controlling tty.)
    debconf: falling back to frontend: Teletype
    debconf: unable to initialize frontend: Teletype
    debconf: (This frontend requires a controlling tty.)
    debconf: falling back to frontend: Noninteractive
    ```
11. First attempt of provision-service resulted in the following

      ```terminal
      tim@MacBook-Pro n8n-server-setup % ./provision-service.sh --env dev --host rpicm5b --service n8n
      [provision-service.sh] ERROR: Service 'n8n' not found in repo at /opt/n8n/services/n8n. Is it supported?
      tim@MacBook-Pro n8n-server-setup % ./provision-service.sh --env dev --host rpicm5b --service n8n
      ```
12. Modify docler-compose.yml to include the generated .env file.
