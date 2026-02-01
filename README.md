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

## Optional: Postgres access from TablePlus (LAN)

By default this stack can expose Postgres on the host for convenience (TablePlus, etc.).
This is controlled by:

- `POSTGRES_BIND_IP` (in `.env`)

Examples:

- **Safer default (host-only):**
  - `POSTGRES_BIND_IP=127.0.0.1`
  - Use SSH tunneling when needed:
    ```bash
    ssh -L 5432:127.0.0.1:5432 tim@n8n
    ```
  - Then connect TablePlus to `localhost:5432`

- **LAN convenience mode:**
  - `POSTGRES_BIND_IP=<host VLAN interface IP>` (e.g. `10.20.0.6`)
  - Strongly recommended: restrict access with UniFi firewall rules so only your admin laptop can reach TCP/5432.

## Notes

- This repo intentionally does not attempt to integrate 1Password CLI (`op`) on the server.
  Secrets are copy/pasted manually from 1Password into `.env`.
- When moving to HTTPS (Traefik/Caddy), you will update `.env` (host/protocol/webhook URL) and remove
  `N8N_SECURE_COOKIE=false`.

---

## TODO: Restrict Postgres LAN Access with UniFi Firewall Rules

Postgres is optionally exposed on the host to allow convenient access from tools
like TablePlus during n8n workflow development. This increases the blast radius
unless access is explicitly restricted.

**Planned mitigation (recommended):**

### Preconditions

- Assign a **static / reserved IP** to your admin laptop (DHCP reservation).
- Ensure the n8n host has a **stable IP** on its VLAN (e.g. VLAN 20).

### Firewall policy (conceptual)

Create rules on the UniFi gateway in the **LAN IN** (or equivalent) rule set,
ordered as shown:

1. **Allow admin laptop → Postgres**
   - Action: **Accept**
   - Protocol: **TCP**
   - Source: **Admin laptop IP**
   - Destination: **n8n host IP** (e.g. `10.20.0.6`)
   - Destination port: **5432**
   - Comment: `Allow TablePlus access to n8n Postgres`

2. **Block all other Postgres access**
   - Action: **Drop** (or Reject if you prefer explicit feedback)
   - Protocol: **TCP**
   - Source: **Any**
   - Destination: **n8n host IP**
   - Destination port: **5432**
   - Comment: `Block Postgres access to n8n host`

This preserves TablePlus convenience while preventing lateral access from other
hosts or VLANs.

### Alternative (safer) mode

Instead of exposing Postgres on the LAN:

- Set `POSTGRES_BIND_IP=127.0.0.1`
- Use SSH port forwarding when needed:

  ```bash
  ssh -L 5432:127.0.0.1:5432 tim@n8n
  ```

- Connect TablePlus to `localhost:5432`

