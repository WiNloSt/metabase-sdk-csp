#!/usr/bin/env bash
# One command to run the harness. Runs a preflight (tools, deps, secret, paths,
# reachability), then starts the JWT auth-server in the background and Caddy in
# the foreground. Ctrl-C stops both.
#
# Fatal problems abort before anything starts, with a fix. Soft problems (e.g.
# Metabase not up yet) warn but continue.
set -euo pipefail
cd "$(dirname "$0")"

red()  { printf '\033[31m%s\033[0m\n' "$1"; }
yel()  { printf '\033[33m%s\033[0m\n' "$1"; }
grn()  { printf '\033[32m%s\033[0m\n' "$1"; }
die()  { red "ERROR: $1"; shift; for line in "$@"; do echo "  $line"; done; exit 1; }
warn() { yel "WARN: $1"; shift; for line in "$@"; do echo "  $line"; done; }

# Reachability helpers (curl ships with macOS; nc as a fallback for raw ports).
http_up() { curl -fsS -o /dev/null --max-time 2 "$1" 2>/dev/null; }
port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

METABASE_URL="${VITE_METABASE_INSTANCE_URL:-http://localhost:3000}"
COLLECTOR_URL="${VITE_COLLECTOR_URL:-http://localhost:9090}"
SDK_DIST="../metabase/resources/embedding-sdk/dist/main.bundle.js"

echo "==> preflight"

# --- tools (fatal) ---
command -v caddy >/dev/null 2>&1 || die "caddy not found." "Install: brew install caddy"
command -v node  >/dev/null 2>&1 || die "node not found." "Install Node 20.6+ (this harness uses node --env-file)."
command -v npm   >/dev/null 2>&1 || die "npm not found."

# --- env + JWT secret (fatal) ---
ENV_FILE=.env
[ -f "$ENV_FILE" ] || die "$ENV_FILE missing." \
  "cp .env.example .env" \
  "then set METABASE_JWT_SHARED_SECRET (Admin > Settings > Authentication > JWT)."
SECRET=$(grep -E '^METABASE_JWT_SHARED_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d "\"' \r")
{ [ -n "$SECRET" ] && [ "$SECRET" != "PASTE_JWT_SIGNING_KEY_HERE" ]; } || die \
  "METABASE_JWT_SHARED_SECRET is not set in $ENV_FILE." \
  "Paste the value from Admin > Settings > Authentication > JWT > 'String used by the JWT signing key'."

# --- SDK loader present (fatal) ---
[ -f "$SDK_DIST" ] || die "Built SDK loader not found at $SDK_DIST." \
  "Build it in the Metabase repo: bun run build-embedding-sdk-package" \
  "(This harness expects the metabase checkout as a sibling: ../metabase)"

# --- deps (auto-install if missing) ---
[ -d auth-server/node_modules ] || { echo "==> installing auth-server deps"; (cd auth-server && npm install); }
[ -d app/node_modules ]         || { echo "==> installing app deps";        (cd app && npm install); }

# --- ports (fatal if busy: we are about to bind them) ---
port_busy 8088 && die "Port 8088 is already in use (Caddy needs it)." "Stop whatever is on :8088, or change the port in Caddyfile."
port_busy 8089 && die "Port 8089 is already in use (auth-server needs it)." "Stop it, or set AUTH_PORT in auth-server/.env."

# --- soft checks (warn only) ---
http_up "$METABASE_URL/api/health" || warn "Metabase not reachable at $METABASE_URL." \
  "Start it (and run 'bun run build-hot' so the instance serves the telemetry bundle)."
http_up "$COLLECTOR_URL/micro/all" || warn "Snowplow Micro not reachable at $COLLECTOR_URL." \
  "Forwarded events won't be observable until Micro is up. The proxy 2xx is still visible in the Network tab."

# --- build the app if needed ---
if [ ! -d app/dist ]; then
  echo "==> building app (app/dist missing)"
  (cd app && npm run build)
fi

grn "==> preflight OK"

echo "==> starting JWT auth-server (background)"
(cd auth-server && exec node --env-file-if-exists=../.env server.mjs) &
AUTH_PID=$!
trap 'echo; echo "==> stopping auth-server"; kill "$AUTH_PID" 2>/dev/null || true' EXIT INT TERM

URL="http://csp.localhost:8088"
print_banner() {
  local cyan='\033[1;36m' reset='\033[0m' url='\033[1;4;92m' dim='\033[2m'
  local w=44 line row
  line=$(printf '━%.0s' $(seq 1 $w))
  # ASCII only in padded content so byte width == column width (%-*s pads bytes).
  row=$(printf "%-*s" "$w" "  harness ready - open in your browser:")
  echo
  printf "  ${cyan}┏${line}┓${reset}\n"
  printf "  ${cyan}┃${reset}%s${cyan}┃${reset}\n" "$row"
  printf "  ${cyan}┃${reset}%-*s${cyan}┃${reset}\n" "$w" ""
  printf "  ${cyan}┃${reset}    ${url}%s${reset}%-*s${cyan}┃${reset}\n" "$URL" "$((w - 4 - ${#URL}))" ""
  printf "  ${cyan}┗${line}┛${reset}\n"
  printf "  ${dim}(Ctrl-C stops Caddy + the auth-server)${reset}\n"
  echo
}
print_banner
caddy run
