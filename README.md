# n8n (homelab) deployment

This repo contains the artifacts needed to deploy an n8n stack under:

- `/opt/n8n`
- Docker Compose
- Postgres (`postgres:16-alpine`)
- Persistent data on the filesystem (bind mounts)

It is designed for a single-user homelab machine where the primary user (e.g. `tim`)
has `sudo` access.

---

## What’s in this repo

- `docker-compose.yml` — n8n + postgres services
- `.env.example` — template for runtime environment variables (NO secrets)
- `setup.sh` — creates directories, sets ownership/permissions, creates `.env` if missing
- Optional: scripts you may add later:
  - `scripts/backup.sh`, `scripts/restore.sh`

---

## Security model (high level)

- The real `.env` file is **never committed**.
- Postgres data directory is owned by Postgres’ container UID/GID (**70:70** for `postgres:16-alpine`)
  and permissions are **700**. This prevents accidental reads/writes by normal users on the host.
- n8n’s persistence directory (`/opt/n8n/data`) is owned by the local admin user and is readable/writable
  without `sudo`.
- For HTTP-only LAN access, set `N8N_SECURE_COOKIE=false`. When you later add HTTPS/reverse-proxy, remove
  that override.

---

## One-time install (fresh machine)

### 1) Create `/opt/n8n` and clone this repo into it

Recommended safe approach:

```bash
sudo mkdir -p /opt/n8n
sudo chown "$USER":"$USER" /opt/n8n

cd /opt/n8n
git clone <YOUR_REPO_URL> .
```

> Note: Cloning into `.` keeps the directory name fixed as `/opt/n8n`,
> regardless of the repo name.

### 2) Run setup

```bash
cd /opt/n8n
sudo ./setup.sh
```

This will:

- create folders data, postgres, and backups
- apply ownership + permissions
- create `.env` from `.env.example` if it doesn’t exist
- verify required variables exist in `.env` (but not their values)

### 3) Create/edit `.env`

Copy/paste secrets from 1Password into:

- `N8N_ENCRYPTION_KEY` (must never change)
- `POSTGRES_PASSWORD`

Optional but commonly needed for HTTP-only LAN setups:

- `N8N_SECURE_COOKIE=false`

```bash
nano /opt/n8n/.env
chmod 600 /opt/n8n/.env
```

### 4) Start the stack

```bash
cd /opt/n8n
docker compose up -d
docker compose ps
```

Open:

- `http://<host>:5678` or `http://n8n.iot:5678` (depending on your DNS)

---

## Daily operations

From `/opt/n8n`:

- Start: `docker compose up -d`
- Stop: `docker compose down`
- Logs: `docker compose logs -f n8n` and `docker compose logs -f postgres`
- Status: `docker compose ps`

---

## Backups (recommended approach)

Logical database backup using `pg_dump` (safe + consistent):

```bash
mkdir -p /opt/n8n/backups
chmod 700 /opt/n8n/backups

docker exec -t n8n-postgres pg_dump -U n8n -d n8n | gzip > /opt/n8n/backups/n8n-$(date +%F).sql.gz
ls -lh /opt/n8n/backups
```

Restore example (careful: overwrites data):

```bash
gunzip -c /opt/n8n/backups/n8n-YYYY-MM-DD.sql.gz | docker exec -i n8n-postgres psql -U n8n -d n8n
```

---

## Notes

- This repo intentionally does not attempt to integrate 1Password CLI (`op`) on the server.
  Secrets are copy/pasted manually from 1Password into `.env`.
- When moving to HTTPS (Traefik/Caddy), you will update `.env` (host/protocol/webhook URL) and remove
  `N8N_SECURE_COOKIE=false`.

---
