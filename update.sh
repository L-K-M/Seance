#!/usr/bin/env bash
#
# Update a Séance sync-server deployment: pull the latest code and rebuild +
# recreate the Docker stack.
#
#   ./update.sh [branch]
#
# Syncs the current branch by default (pass a branch name to override). Requires:
#   - git with pull access to this repo (the GitHub CLI `gh` is used when
#     present, with a plain `git pull --ff-only` fallback)
#   - Docker with the Compose plugin
set -euo pipefail

cd "$(dirname "$0")"

# The compose file lives with the server package; the build context is the repo
# root (this directory), so compose must run from here via -f.
COMPOSE_FILE=packages/seance_sync_server/docker-compose.yml

branch="${1:-$(git rev-parse --abbrev-ref HEAD)}"

# The rebuild uses the checked-out tree, so an explicitly named branch must
# actually be checked out — syncing it alone would redeploy the old branch.
if [[ "$branch" != "$(git rev-parse --abbrev-ref HEAD)" ]]; then
    echo "==> Switching to '$branch'…"
    git checkout "$branch"
fi

echo "==> Syncing '$branch' from the remote…"
if command -v gh >/dev/null 2>&1; then
    if ! gh repo sync --branch "$branch"; then
        echo "    gh repo sync failed; falling back to: git pull --ff-only" >&2
        git pull --ff-only origin "$branch"
    fi
else
    git pull --ff-only origin "$branch"
fi

echo "==> Rebuilding the image and recreating the container…"
docker compose -f "$COMPOSE_FILE" up -d --build --remove-orphans

echo "==> Pruning dangling images…"
docker image prune -f >/dev/null || true

echo "==> Stack status:"
docker compose -f "$COMPOSE_FILE" ps
