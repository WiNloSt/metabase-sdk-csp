#!/usr/bin/env bash
# Single command to run the harness: builds the app if needed, starts the JWT
# auth-server in the background, and runs Caddy in the foreground. Ctrl-C stops
# both.
#
# Prereqs: auth-server/.env has METABASE_JWT_SHARED_SECRET set (copy .env.example).
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d app/dist ]; then
  echo "==> app/dist missing — building app"
  (cd app && npm run build)
fi

echo "==> starting JWT auth-server (background)"
# exec so $! is the node PID (clean kill on exit).
(cd auth-server && exec node --env-file-if-exists=.env server.mjs) &
AUTH_PID=$!
trap 'echo; echo "==> stopping auth-server"; kill "$AUTH_PID" 2>/dev/null || true' EXIT INT TERM

echo "==> starting Caddy on http://localhost:8088 (Ctrl-C to stop both)"
caddy run
