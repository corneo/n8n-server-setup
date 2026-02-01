#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# setup.sh - prepare /opt/n8n for n8n + postgres bind-mount deployment
#
# Safe to re-run. Does NOT start containers. Does NOT overwrite existing .env.
#
# Assumptions:
# - Repo cloned into /opt/n8n
# - Postgres image is postgres:16-alpine (postgres user is UID/GID 70)
# ------------------------------------------------------------------------------

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults for postgres:16-alpine (verified: postgres user is uid=70 gid=70)
POSTGRES_UID_DEFAULT=70
POSTGRES_GID_DEFAULT=70

# Allow override via environment if you ever change images/UIDs
POSTGRES_UID="${POSTGRES_UID:-$POSTGRES_UID_DEFAULT}"
POSTGRES_GID="${POSTGRES_GID:-$POSTGRES_GID_DEFAULT}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# --- Safety checks ------------------------------------------------------------

[[ "$APP_DIR" == "/opt/n8n" ]] || die "This script must be run from /opt/n8n (current: $APP_DIR)."

if [[ "${EUID}" -ne 0 ]]; then
  die "Run with sudo: sudo ./setup.sh"
fi

# Determine the "human" owner (the user who invoked sudo)
# logname works well for sudo; fall back to SUDO_USER if needed.
OWNER_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
[[ -n "${OWNER_USER}" ]] || die "Could not determine invoking user (SUDO_USER/logname)."

OWNER_GROUP="$(id -gn "$OWNER_USER")"

info "Using owner: ${OWNER_USER}:${OWNER_GROUP}"
info "Using postgres UID:GID for data dir: ${POSTGRES_UID}:${POSTGRES_GID}"

# --- Ensure expected files exist ---------------------------------------------

[[ -f "${APP_DIR}/docker-compose.yml" ]] || die "Missing docker-compose.yml in ${APP_DIR}"
[[ -f "${APP_DIR}/.env.example" ]] || die "Missing .env.example in ${APP_DIR}"

# --- Create directories -------------------------------------------------------

info "Creating directories: data/ postgres/ backups/"
mkdir -p "${APP_DIR}/data" "${APP_DIR}/postgres" "${APP_DIR}/backups"

# --- Ownership & permissions --------------------------------------------------
#
# General repo contents should be owned by the human owner.
# Postgres directory must be owned by the postgres container UID/GID and locked down.

info "Setting ownership for repo files to ${OWNER_USER}:${OWNER_GROUP}"
chown -R "${OWNER_USER}:${OWNER_GROUP}" "${APP_DIR}"

info "Locking down postgres data directory (700) and setting ownership to ${POSTGRES_UID}:${POSTGRES_GID}"
chown -R "${POSTGRES_UID}:${POSTGRES_GID}" "${APP_DIR}/postgres"
chmod 700 "${APP_DIR}/postgres"

info "Setting permissions:"
info "  data/    -> 750 (owner full; group read/execute; no access for others)"
chmod 750 "${APP_DIR}/data"

info "  backups/ -> 700 (owner only)"
chmod 700 "${APP_DIR}/backups"

# --- .env creation (non-destructive) -----------------------------------------

if [[ ! -f "${APP_DIR}/.env" ]]; then
  info "Creating .env from .env.example"
  cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
  chown "${OWNER_USER}:${OWNER_GROUP}" "${APP_DIR}/.env"
  chmod 600 "${APP_DIR}/.env"
  info "Created .env (mode 600). You must edit it and paste secrets from 1Password."
else
  info ".env already exists; leaving it untouched"
  chmod 600 "${APP_DIR}/.env" || true
fi

# --- Validate required keys exist in .env (values may be blank) --------------

require_keys=(
  "N8N_ENCRYPTION_KEY"
  "POSTGRES_DB"
  "POSTGRES_USER"
  "POSTGRES_PASSWORD"
)

info "Validating required keys exist in .env (values may be blank at this stage)"
missing=0
for k in "${require_keys[@]}"; do
  if ! grep -Eq "^[[:space:]]*${k}=" "${APP_DIR}/.env"; then
    echo "  Missing key: ${k}"
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo
  die "One or more required keys are missing from .env. Fix .env and re-run setup.sh."
fi

info "Setup complete."
echo
echo "Next steps:"
echo "  1) Edit /opt/n8n/.env and paste secrets from 1Password:"
echo "       - N8N_ENCRYPTION_KEY (must never change)"
echo "       - POSTGRES_PASSWORD"
echo "     Optional for HTTP LAN access:"
echo "       - N8N_SECURE_COOKIE=false"
echo "  2) Start the stack:"
echo "       cd /opt/n8n && docker compose up -d"
echo "  3) Check status:"
echo "       docker compose ps"