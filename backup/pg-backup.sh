#!/usr/bin/env bash
#
# Logical backup (pg_dump, gzipped) of one app's Postgres.
#
# Usage: ./pg-backup.sh <app-name>
#
# Runs pg_dump inside the app's own `postgres` compose service, so no Postgres
# client or credentials are needed on the host: the official image sets
# POSTGRES_USER and POSTGRES_DB inside the container, which keeps this script
# the same for every app. Output: /var/backups/<app-name>/<app-name>-<stamp>.sql.gz,
# readable by root only (dumps contain password hashes). Dumps older than
# RETENTION_DAYS are deleted.
#
# Same-disk only: this survives mistakes and bad migrations, not losing the VPS.

set -euo pipefail
umask 077

APPS_ROOT="/srv"
BACKUP_ROOT="/var/backups"
RETENTION_DAYS=14

app_name="${1:-}"
if [[ -z "$app_name" ]]; then
  echo "Usage: $0 <app-name>" >&2
  exit 1
fi

app_dir="${APPS_ROOT}/${app_name}"
if [[ ! -f "$app_dir/docker-compose.yml" ]]; then
  echo "Error: $app_dir/docker-compose.yml not found" >&2
  exit 1
fi

dest_dir="${BACKUP_ROOT}/${app_name}"
mkdir -p "$dest_dir"

stamp="$(date +%Y%m%d-%H%M%S)"
out="${dest_dir}/${app_name}-${stamp}.sql.gz"
tmp="${out}.partial"
trap 'rm -f "$tmp"' EXIT

# Write to a .partial file and rename on success, so a failed dump can never
# be mistaken for a good one (and never counts toward retention).
docker compose -f "$app_dir/docker-compose.yml" --project-directory "$app_dir" \
  exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip > "$tmp"
mv "$tmp" "$out"

find "$dest_dir" -name "${app_name}-*.sql.gz" -mtime +"$RETENTION_DAYS" -delete

echo "==> Backup written: $out ($(du -h "$out" | cut -f1))"
