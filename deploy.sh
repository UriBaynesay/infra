#!/usr/bin/env bash
#
# Deploy (or redeploy) one app from this project's suite onto this VPS.
#
# Usage: ./deploy.sh <app-name>
#
# Looks up <app-name> in apps.conf for its git URL, clones it to
# /srv/<app-name> on first run or `git pull`s it on every run after, then
# brings its Docker Compose stack up. Scoped to exactly one app per
# invocation — never touches any other app's directory.
#
# Requires a real /srv/<app-name>/.env to already exist on the server
# before the first run — this script never creates or touches it.
# Secrets are hand-placed on the server once, never generated or committed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_CONF="${SCRIPT_DIR}/apps.conf"
APPS_ROOT="/srv"

app_name="${1:-}"
if [[ -z "$app_name" ]]; then
  echo "Usage: $0 <app-name>" >&2
  echo "Known apps:" >&2
  grep -Ev '^\s*(#|$)' "$APPS_CONF" | cut -d= -f1 | sed 's/^/  - /' >&2
  exit 1
fi

repo_url="$(grep -E "^${app_name}=" "$APPS_CONF" | cut -d= -f2- || true)"
if [[ -z "$repo_url" ]]; then
  echo "Error: '$app_name' is not listed in $APPS_CONF" >&2
  exit 1
fi

app_dir="${APPS_ROOT}/${app_name}"

if [[ -d "$app_dir/.git" ]]; then
  echo "==> $app_name already cloned at $app_dir — pulling latest"
  git -C "$app_dir" pull
else
  echo "==> Cloning $app_name into $app_dir"
  git clone "$repo_url" "$app_dir"
fi

if [[ ! -f "$app_dir/.env" ]]; then
  echo "Error: $app_dir/.env does not exist." >&2
  echo "Create it by hand on this server before deploying — it is never generated or committed." >&2
  exit 1
fi

echo "==> Bringing up $app_name (docker-compose.yml explicitly, ignoring any override file)"
docker compose -f "$app_dir/docker-compose.yml" --project-directory "$app_dir" up -d --build

echo "==> Done. $app_name is up. Remember to run any pending DB migrations by hand:"
echo "    docker compose -f $app_dir/docker-compose.yml exec app <migrate command>"
