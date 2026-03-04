#!/usr/bin/env bash
# provision-host.sh — Prepare a bare Raspberry Pi host for Docker-based services
#
# Runs on the admin workstation (macBook). Executes all steps on the target
# host via SSH. Safe to re-run on an already-provisioned host.
#
# Prerequisites on the admin workstation:
#   - SSH access to the target host as ops (key-based)
#   - 1Password CLI (op) installed and authenticated
#
# Prerequisites on the target host:
#   - Account 'ops' exists with passwordless sudo
#     (add to /etc/sudoers.d/ops: ops ALL=(ALL) NOPASSWD:ALL)
#   - Internet access
#
# Usage:
#   ./provision-host.sh --env <dev|prod> --host <hostname>
#
# Example:
#   ./provision-host.sh --env dev --host rpicm5b

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/lib.sh"

# ── Argument Parsing ──────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 --env <dev|prod> --host <hostname>"
  exit 1
}

ENV=""
HOST=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)  ENV="$2";  shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$ENV" || -z "$HOST" ]] && usage

# ── Configuration ─────────────────────────────────────────────────────────────

VAULT=$(vault_for_env "$ENV")
TARGET="ops@${HOST}"
REPO_URL="git@github.com:corneo/home-lab.git"
INSTALL_DIR="/opt/n8n"
GITHUB_KEY_REF="op://${LAB_VAULT}/sshkey.github/private key?ssh-format=openssh"

# ── Preflight ─────────────────────────────────────────────────────────────────

command -v op  &>/dev/null || die "1Password CLI (op) not found on this machine."
command -v jq  &>/dev/null || die "jq not found on this machine. Install with: brew install jq"
ssh -q -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" true \
  || die "Cannot reach $TARGET via SSH. Check connectivity and key-based auth."

log "Provisioning host: $HOST (env: $ENV, vault: $VAULT)"

# ── Phase 1: System update ────────────────────────────────────────────────────

log "Phase 1: System update and base packages..."
ssh "$TARGET" "sudo DEBIAN_FRONTEND=noninteractive apt update \
  && sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade -y \
  && sudo DEBIAN_FRONTEND=noninteractive apt install -y jq"

# ── Phase 2: Install Docker ───────────────────────────────────────────────────

log "Phase 2: Installing Docker..."
ssh "$TARGET" bash << 'ENDSSH'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Skip if Docker is already installed
if command -v docker &>/dev/null; then
  echo "Docker already installed — skipping."
  exit 0
fi

sudo apt install -y ca-certificates curl

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null << EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

sudo systemctl enable docker
sudo systemctl start docker
echo "Docker installed successfully."
ENDSSH

# ── Phase 3: Add ops to docker group and verify Docker installation ─────────-

log "Phase 3: Adding ops to docker group..."
ssh "$TARGET" \
  "sudo usermod -aG docker ops & newgrp docker & sudo docker run hello-world"

# ── Phase 4: Install 1Password CLI ───────────────────────────────────────────

log "Phase 4: Installing 1Password CLI..."
ssh "$TARGET" bash << 'ENDSSH'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Skip if op is already installed
if command -v op &>/dev/null; then
  echo "1Password CLI already installed — skipping."
  exit 0
fi

ARCH=$(dpkg --print-architecture)

curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
  | sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg

echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] \
  https://downloads.1password.com/linux/debian/${ARCH} stable main" \
  | sudo tee /etc/apt/sources.list.d/1password.list

sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22/
curl -sS https://downloads.1password.com/linux/debian/debsig/1password.policy \
  | sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.policy

sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
curl -sS https://downloads.1password.com/linux/keys/1password.asc \
  | sudo gpg --dearmor \
    --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg

sudo apt update && sudo apt install -y 1password-cli
echo "1Password CLI installed: $(op --version)"
ENDSSH


# ── Phase 5: Place GitHub SSH key ────────────────────────────────────────────

log "Phase 5: Installing GitHub SSH key..."
op read "$GITHUB_KEY_REF" \
  | ssh "$TARGET" "install -m 600 /dev/stdin /home/ops/.ssh/id_ed25519"

# Verify GitHub connectivity from the host
log "Verifying GitHub SSH authentication..."
ssh "$TARGET" "ssh -T -o StrictHostKeyChecking=accept-new git@github.com 2>&1 | grep -q 'successfully authenticated'" \
  && log "GitHub auth OK." \
  || log "Warning: GitHub SSH auth check inconclusive — continuing."

# ── Phase 5b: Place 1Password service account token on host ──────────────────

log "Phase 5b: Installing 1Password service account token..."
OP_TOKEN=$(op item get "op-service-account" --vault "$VAULT" --fields credential --reveal)
echo "export OP_SERVICE_ACCOUNT_TOKEN=${OP_TOKEN}" \
  | ssh "$TARGET" "install -m 600 /dev/stdin /home/ops/.op_env"
log "OP service account token installed at /home/ops/.op_env (mode 600)."

# ── Phase 6: Clone or update repo ────────────────────────────────────────────

log "Phase 6: Cloning repo to ${INSTALL_DIR}..."
ssh "$TARGET" bash << ENDSSH
set -euo pipefail

if [ -d "${INSTALL_DIR}/.git" ]; then
  echo "Repo already present — pulling latest..."
  git -C "${INSTALL_DIR}" pull
else
  sudo mkdir -p "${INSTALL_DIR}"
  sudo chown ops:ops "${INSTALL_DIR}"
  git clone "${REPO_URL}" "${INSTALL_DIR}"
fi
ENDSSH

# ── Phase 7: Set permissions on scripts ──────────────────────────────────────

log "Phase 7: Setting script permissions..."
ssh "$TARGET" "find ${INSTALL_DIR} -name '*.sh' -exec chmod +x {} \;"


# ── Done ──────────────────────────────────────────────────────────────────────

log " "
log "Host provisioning complete."
log "  Host:    $HOST"
log "  Env:     $ENV"
log "  Repo:    $INSTALL_DIR"
log " "
log "IMPORTANT: User 'ops' must log out and back in or run 'newgrp docker' to"
log "           activate docker group membership before deploying services."
log " "
log "Next step: ./provision-service.sh --env $ENV --host $HOST --service <name>"
log "          or: ./provision.sh [spec.yaml]"
