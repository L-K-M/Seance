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
#
# Per-deployment compose overrides (e.g. SEANCE_PUBLISH_ADDR when the reverse
# proxy runs in a container) live in packages/seance_sync_server/.env —
# gitignored, so the pull never fights it. See .env.example there.
set -euo pipefail

cd "$(dirname "$0")"

# The compose file lives with the server package; the build context is the repo
# root (this directory), so compose must run from here via -f.
COMPOSE_FILE=packages/seance_sync_server/docker-compose.yml
ENV_FILE=packages/seance_sync_server/.env

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

# Pass the deployment's .env explicitly so its overrides apply regardless of
# compose version or working directory.
compose=(docker compose -f "$COMPOSE_FILE")
if [[ -f "$ENV_FILE" ]]; then
    echo "==> Using overrides from $ENV_FILE"
    compose+=(--env-file "$ENV_FILE")
fi

echo "==> Rebuilding the image and recreating the container…"
"${compose[@]}" up -d --build --remove-orphans

echo "==> Pruning dangling images…"
docker image prune -f >/dev/null || true

# `up -d` reports success even if the process inside dies right away, and a
# port published somewhere the reverse proxy can't reach surfaces only as a 502
# in the app much later. Probe the published /healthz endpoint so a broken
# deploy fails HERE, with logs, instead.
echo "==> Waiting for the server to answer…"
# `|| true`: under set -e a non-zero `compose port` (no port published) must
# fall through to the skip branch below, not kill the script.
endpoint="$("${compose[@]}" port seance-sync 8787 2>/dev/null | head -n1 || true)"
# Wildcard binds come back in several shapes depending on the CLI version;
# normalize them all to a loopback-reachable host:port. Anchored (`/#`) so a
# real address that merely contains a wildcard substring is left alone.
endpoint="${endpoint/#0.0.0.0/127.0.0.1}"
endpoint="${endpoint/#\[::\]/127.0.0.1}"
endpoint="${endpoint/#:::/127.0.0.1:}"
if [[ -z "$endpoint" ]]; then
    echo "    No published port found — skipping the health probe." >&2
elif [[ ! "$endpoint" =~ ^[^:]+:[0-9]+$ ]]; then
    echo "    Unrecognized published endpoint '$endpoint' — skipping the health probe." >&2
elif ! command -v curl >/dev/null 2>&1; then
    echo "    curl not found — skipping the health probe." >&2
else
    # Wall-clock deadline, not an attempt count: a wedged-but-accepting server
    # makes each curl burn its --max-time, which would stretch "30 attempts"
    # to minutes.
    healthy=
    deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        if curl -fs --max-time 2 -o /dev/null "http://$endpoint/healthz"; then
            healthy=1
            break
        fi
        sleep 1
    done
    if [[ -n "$healthy" ]]; then
        echo "    Server answering on http://$endpoint/healthz"
    else
        echo "!!! Server did not answer on http://$endpoint/healthz within ~30s." >&2
        echo "!!! Container status and recent logs:" >&2
        "${compose[@]}" ps >&2
        "${compose[@]}" logs --tail=40 seance-sync >&2
        echo "!!! If a containerized reverse proxy fronts this server, check" >&2
        echo "!!! SEANCE_PUBLISH_ADDR in $ENV_FILE (see .env.example)." >&2
        exit 1
    fi
fi

echo "==> Stack status:"
"${compose[@]}" ps
