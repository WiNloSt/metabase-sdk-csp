# Embedding SDK strict-CSP telemetry harness

A small repo to verify, by hand, that the Embedding SDK can send usage telemetry
from a page with a **strict Content-Security-Policy** — the scenario this PR is about.

## What it proves

When the SDK runs in a customer's app, the customer's `connect-src` CSP usually
doesn't allow Metabase's Snowplow collector, so a direct telemetry POST is blocked
by the browser. The fix routes telemetry through the customer's own Metabase
instance (already allowed by their CSP), which forwards it to the collector
server-side. This harness serves an SDK app at **`http://csp.localhost:8088`** —
a strict-CSP page on a *different* origin from Metabase — and lets you confirm:

- a **direct** collector POST is **blocked** by CSP, and
- the SDK's POST **through the instance proxy** (`/api/analytics/snowplow-proxy`)
  **passes** and the event reaches the collector.

Layout: `Caddyfile` (serves the app under the strict CSP), `auth-server/` (signs a
JWT for SSO), `app/` (Vite + React app using the locally-built SDK).

## Prerequisites

- This repo checked out as a **sibling** of your `metabase` checkout (e.g.
  `src/metabase` and `src/metabase-sdk-csp`). `app/package.json` links the SDK via
  `file:../../metabase/resources/embedding-sdk` (relative to `app/`); if your
  `metabase` is elsewhere, adjust that path and `SDK_DIST` in `start.sh`.
- The Metabase instance running at `http://localhost:3000` from **this PR's branch**
  (it needs the proxy endpoint + SDK telemetry), with an EE token.
- **JWT SSO** enabled: Admin → Settings → Authentication → JWT. Copy *"String used
  by the JWT signing key"*.
- **`csp.localhost:8088` added to the SDK CORS origins**: Admin → Embedding →
  Modular embedding (SDK) → authorized origins (or env
  `MB_EMBEDDING_APP_ORIGINS_SDK=csp.localhost:8088`).
- **Snowplow Micro** running at `http://localhost:9090` (the local collector) so
  forwarded events are observable.
- `caddy` and `node` installed. Browsers resolve `*.localhost` to 127.0.0.1
  automatically — nothing to add to `/etc/hosts`.

## Run

```bash
cd metabase-sdk-csp
cp .env.example .env          # set METABASE_JWT_SHARED_SECRET (the JWT signing key)
./start.sh                    # preflight, then auth-server + Caddy; Ctrl-C stops both
```

In the Metabase repo, build the SDK so the instance serves it:
`bun run build-hot`.

Then open **<http://csp.localhost:8088>** with DevTools (Console + Network).

`.env` keys: `METABASE_JWT_SHARED_SECRET` (required), `AUTH_PORT` (8089),
`VITE_METABASE_INSTANCE_URL` (`http://localhost:3000`), `VITE_DASHBOARD_ID` (a
dashboard you have), `VITE_COLLECTOR_URL` (`http://localhost:9090`).

## Verify

1. **CSP is strict** — the document response has a `Content-Security-Policy` header
   whose `connect-src` lists `http://localhost:3000` but **not** `http://localhost:9090`.
2. **Baseline is blocked** — click *"Baseline: fire direct collector POST"*. The
   console shows a CSP violation (`Refused to connect to 'http://localhost:9090/…'`)
   and no request leaves the browser.
3. **Proxy passes** — in Network, the SDK's `POST /api/analytics/snowplow-proxy`
   (to `localhost:3000`) returns **2xx**, no CSP violation.
4. **Event lands** — open <http://localhost:9090/micro/all>; the `good` count
   increments with the SDK's `setup` event.

Steps 2 and 4 are the evidence: blocked directly, delivered via the proxy.

## Troubleshooting

`./start.sh` preflights and aborts on fatal problems (missing `caddy`/`node`,
unset JWT secret, busy ports, missing built SDK) with a fix inline; it warns if
Metabase or Micro aren't reachable.

| Symptom | Cause | Fix |
|---|---|---|
| Blank page, no SDK UI | Instance not serving the bundle, or origin not allowlisted | `bun run build-hot` in metabase; add `csp.localhost:8088` to SDK CORS origins |
| CORS error on `/auth/sso`, the proxy, or `/app/fonts/*` (no `Access-Control-Allow-Origin`) | `csp.localhost:8088` not allowlisted | Add it to the SDK CORS origins. Server-side CORS, not the page CSP |
| Login / SSO error | JWT secret mismatch or JWT SSO disabled | `.env` secret must equal Admin → Auth → JWT signing key; enable JWT SSO |
| Proxy POST returns 401 | Backend not on this PR's branch | Run the instance from the PR branch (the proxy is public); restart the backend |
| Console: `ws://csp.localhost:8080/ws` violates `connect-src` | `build-hot` HMR socket | Harmless (dev hot-reload only); ignore |
| Proxy POST 2xx but nothing in Micro | Micro down or stale bundle | Start Micro at `:9090`; re-run `build-hot` |
| Baseline button shows no violation | Page not served via Caddy | Open `http://csp.localhost:8088` (Caddy), not a Vite dev server |
