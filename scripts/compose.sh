#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  echo "Es fehlt .env. Starte zuerst ./first_install.sh." >&2
  exit 1
fi

exec docker compose \
  --project-directory "$PROJECT_DIR" \
  --env-file "$PROJECT_DIR/.env" \
  -f "$PROJECT_DIR/docker-compose.yml" \
  "$@"
