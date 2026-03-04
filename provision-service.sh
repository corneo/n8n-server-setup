#!/usr/bin/env bash
# provision-service.sh — Deploy a Docker-based service to a prepared host
#
# Runs on the admin workstation (macBook). The target host must already be
# provisioned with provision-host.sh. Safe to re-run (redeploys / updates).
#
# The repo on the target host is the catalog of supported services.
# A service is supported if services/<name>/ exists in the repo.
#
# Usage:
#   ./provision-service.sh --env <dev|prod> --host <hostname> --service <name>
#
# Example:
#   ./provision-service.sh --env dev --host rpicm5b --service n8n

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/lib.sh"

# ── Argument Parsing ──────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 --env <dev|prod> --host <hostname> --service <name>"
  exit 1
}

ENV=""
HOST=""
SERVICE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)     ENV="$2";     shift 2 ;;
    --host)    HOST="$2";    shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$ENV" || -z "$HOST" || -z "$SERVICE" ]] && usage

# ── Configuration ─────────────────────────────────────────────────────────────

VAULT=$(vault_for_env "$ENV")
TARGET="ops@${HOST}"
INSTALL_DIR="/opt/n8n"
SERVICE_DIR="${INSTALL_DIR}/services/${SERVICE}"

# ── Preflight ─────────────────────────────────────────────────────────────────

command -v op  &>/dev/null || die "1Password CLI (op) not found on this machine."
ssh -q -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" true \
  || die "Cannot reach $TARGET via SSH."

log "Deploying service: $SERVICE on $HOST (env: $ENV, vault: $VAULT)"

# ── Step 1: Pull latest repo ──────────────────────────────────────────────────

log "Step 1: Updating repo on host..."
ssh "$TARGET" "git -C ${INSTALL_DIR} pull"

# Verify service is supported (directory exists in the repo on the host)
ssh "$TARGET" "test -d ${SERVICE_DIR}" \
  || die "Service '${SERVICE}' not found in repo at ${SERVICE_DIR}. Is it supported?"

# ── Step 2: Run pre-deploy hook (if present) ─────────────────────────────────

PRE_DEPLOY="${SERVICE_DIR}/pre-deploy.sh"
if ssh "$TARGET" "test -f ${PRE_DEPLOY}"; then
  log "Step 2: Running pre-deploy hook..."
  ssh "$TARGET" "bash ${PRE_DEPLOY}"
fi

# ── Step 3: Generate .env from 1Password ─────────────────────────────────────

log "Step 3: Generating .env from 1Password (vault: $VAULT, item: service.${SERVICE})..."

# Host sources its own OP service account token (placed by provision-host.sh)
# and calls gen-env.sh locally — secrets never pass through the admin workstation.
ssh "$TARGET" "source ~/.op_env && \
  ${INSTALL_DIR}/common/gen-env.sh \
    --env ${ENV} \
    --item service.${SERVICE} \
    --output ${SERVICE_DIR}/.env"

# ── Step 3: Deploy via Docker Compose ────────────────────────────────────────

log "Step 4: Deploying with Docker Compose..."
ssh "$TARGET" bash << ENDSSH
set -euo pipefail
cd ${SERVICE_DIR}
docker compose pull
docker compose up -d
docker compose ps
ENDSSH

# ── Done ──────────────────────────────────────────────────────────────────────

log ""
log "Service deployment complete."
log "  Service: $SERVICE"
log "  Host:    $HOST"
log "  Env:     $ENV"
