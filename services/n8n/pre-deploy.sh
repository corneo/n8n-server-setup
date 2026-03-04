#!/usr/bin/env bash
# pre-deploy.sh — n8n service pre-deployment setup
#
# Called by provision-service.sh before docker compose up.
# Runs on the target host (not the admin workstation).
# Safe to re-run.

set -euo pipefail

INSTALL_DIR="/opt/n8n"

# n8n data directory — must be writable by the node user (uid 1000) inside the container
mkdir -p "${INSTALL_DIR}/data"
chown 1000:1000 "${INSTALL_DIR}/data"
chmod 770 "${INSTALL_DIR}/data"

# postgres data directory — do NOT pre-create; let postgres initialize it with
# correct ownership (uid 70, gid 0) on first start.
