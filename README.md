# Metabase SDK strict-CSP telemetry harness (EMB-1764)

Proves the end-to-end chain for SDK usage telemetry under a strict customer CSP:

```
SDK (@snowplow/browser-tracker)  →  instance proxy  →  Snowplow collector
        in a strict-CSP page         /api/analytics/      (Snowplow Micro
                                      snowplow-proxy        at :9090 locally)
```

The page's `connect-src` allows the Metabase instance (`http://localhost:3000`)
but **not** the collector (`http://localhost:9090`). A direct collector POST is
therefore CSP-blocked; routing through the instance proxy — same host the SDK
already calls for data — gets the event out.

This harness pairs with the Metabase-side PoC changes:

- Backend proxy: `src/metabase/analytics/api.clj` → `POST /api/analytics/snowplow-proxy`
- SDK emit: `frontend/src/embedding-sdk-bundle/analytics/snowplow.ts`, wired in
  `ComponentProvider`

## Layout

```
Caddyfile            # serves app/dist on :8088 under the strict CSP, proxies /sso/metabase
auth-server/         # tiny Express server that signs a Metabase JWT (the "customer backend")
app/                 # Vite + React app using the locally-built SDK via a file: link
```

The app is served at `http://csp.localhost:8088` — a distinct host from the
instance (`localhost:3000`), so it behaves like a real third-party customer
origin. The JWT provider is reverse-proxied under that same origin, so it counts
as `'self'` — exactly how a customer co-locates their auth backend with their app.

## Prerequisites (on the Metabase instance)

JWT SSO is an Enterprise feature, so the local instance needs an EE token.

1. **Metabase running** at `http://localhost:3000` with an EE/premium token.
2. **JWT SSO enabled**: Admin → Settings → Authentication → JWT → enable. Copy
   the value of *"String used by the JWT signing key"* — that is the shared
   secret the auth-server signs with.
3. **Allow the harness origin for the SDK (required)**: Admin → Embedding →
   Modular embedding (SDK) → add `csp.localhost:8088` to the CORS authorized
   origins (or env `MB_EMBEDDING_APP_ORIGINS_SDK=csp.localhost:8088`, then
   restart). Metabase only sends `Access-Control-Allow-Origin` for approved
   origins; `csp.localhost` is **not** auto-approved (only true loopback hosts —
   `localhost`, `127.0.0.1`, `[::1]` — are). Without this, `/auth/sso`, the
   `/api/analytics/snowplow-proxy` POST, and even `/app/fonts/*` are all
   CORS-blocked. This is server-side CORS, not the page CSP.
4. **Snowplow collector for local dev**: the `snowplow-url` setting defaults to
   `http://localhost:9090` (Snowplow Micro) outside prod. Run Snowplow Micro
   there so forwarded events are observable. (See the iglu-schema-registry repo
   for how to run Micro locally.)

## Configuration (environment)

One gitignored `.env` at the harness root configures everything. Copy the
committed `.env.example` and set the secret:

```bash
cp .env.example .env   # then set METABASE_JWT_SHARED_SECRET
```

The auth-server reads it (`node --env-file=../.env`) and the app build reads it
(Vite `envDir: ".."`). Only `VITE_`-prefixed vars reach the browser, so the JWT
secret stays server-side.

| Variable | Default | Meaning |
|---|---|---|
| `METABASE_JWT_SHARED_SECRET` | _(required)_ | Admin → Auth → JWT → "String used by the JWT signing key". `start.sh` aborts if unset. |
| `AUTH_PORT` | `8089` | Port the JWT server listens on (Caddy proxies `/sso/metabase` to it). |
| `VITE_METABASE_INSTANCE_URL` | `http://localhost:3000` | Metabase instance the SDK targets. |
| `VITE_DASHBOARD_ID` | `1` | Dashboard the app mounts; set to one that exists locally. |
| `VITE_COLLECTOR_URL` | `http://localhost:9090` | Collector the baseline button POSTs to (must be absent from the CSP). |

## Build & run

> **Where the EMB-1764 SDK change lives.** The telemetry code is in the SDK
> *runtime bundle* (`frontend/src/embedding-sdk-bundle/`), which the **Metabase
> instance serves** at `:3000/app/embedding-sdk.js`. The npm package this app
> links is only a thin *loader* that fetches that bundle at runtime. So the thing
> that decides whether telemetry fires is the **instance's bundle**, not the npm
> package and not this app's build.

### 1. Make the instance serve the bundle with the change

In the Metabase repo, run the dev frontend so the bundle recompiles and the
instance serves the updated `app/embedding-sdk.js`:

```bash
cd /Users/kelvin/workspace/metabase
bun run build-hot      # recompiles embedding_sdk_bundle on change
```

(A built/prod-style instance needs a full FE rebuild instead.)

### 2. One-time setup of this harness

```bash
cd /Users/kelvin/workspace/metabase-sdk-csp

# single env file — see "Configuration (environment)" above for what each var means
cp .env.example .env                           # then set METABASE_JWT_SHARED_SECRET

# install deps + build the SDK loader (the app file:-links it)
(cd auth-server && npm install)
(cd app && npm install)
cd /Users/kelvin/workspace/metabase && bun run build-embedding-sdk-package
```

(`npm install` and the loader build are already done in this checkout; rerun the
loader build only if you change the npm package, and `app` build only if you edit
this app.)

### 3. Start everything (single command)

```bash
cd /Users/kelvin/workspace/metabase-sdk-csp
./start.sh             # builds app if needed, starts auth-server + Caddy; Ctrl-C stops both
```

Open <http://csp.localhost:8088> with DevTools (Console + Network) open.

## Verify (the PoC payoff)

1. **CSP is actually strict.** In Network, check the document response carries the
   `Content-Security-Policy` header and that `connect-src` lists `http://localhost:3000`
   but NOT `http://localhost:9090`.

2. **Baseline — direct collector POST is blocked.** Click *"Baseline: fire direct
   collector POST"*. Expect a console violation like:
   `Refused to connect to 'http://localhost:9090/...' because it violates the
   document's Content-Security-Policy directive: "connect-src ...".`
   No request leaves the browser. This is the problem.

3. **Fix — the proxy POST passes.** On load the SDK fires one telemetry event.
   In Network, find the POST to `http://localhost:3000/api/analytics/snowplow-proxy`.
   Expect no CSP violation and a 2xx (see surprise #2 if it 401s).

4. **End — the event lands.** Open Snowplow Micro: <http://localhost:9090/micro/all>
   (or `/micro/good`). The forwarded `embedded_analytics_js` `setup` event with
   `global.source = "sdk"` should appear.

Capture a screenshot of the baseline violation (step 2) and of the event in Micro
(step 4) — that is the evidence that closes EMB-1764.

## Pre-flight findings (already handled in this harness)

Caught while building the harness, before any live run:

- **The SDK npm package is a thin loader, CJS-only.** `dist/main.bundle.js` is a
  webpack bundle; `import { MetabaseProvider }` fails under a `file:`-linked
  `vite build` (rollup can't see CJS named exports). `app/src/App.tsx` uses a
  namespace import + destructure instead.
- **The SDK loads its real bundle from the instance via a `<script>` tag.** It
  injects `<script src="{instanceUrl}/app/embedding-sdk.js">` and the bootstrap
  pulls more chunks from the instance — so `script-src` must include
  `http://localhost:3000`, not just `'self'`. The Caddyfile CSP already does.
- **The CJS bundle externalizes React as `require("react")`.** Because the `file:`
  dep is symlinked, its realpath is outside `node_modules`, so rollup's commonjs
  plugin skipped it and the raw `require()` reached the browser (`require is not
  defined`). `app/vite.config.ts` adds the SDK's real path to
  `commonjsOptions.include` so those requires are rewritten to imports.

## Known surprises this PoC is meant to find

Ranked by likelihood; see the plan's §6 in the Metabase repo
(`.claude/kelvin/2026-05-21-emb-1764-.../01-poc-plan.md`).

1. **CORS / ACAO on the proxy.** The proxy POST is cross-origin
   (`csp.localhost:8088` → `localhost:3000`). If the response lacks
   `Access-Control-Allow-Origin` for `csp.localhost:8088`, the browser blocks
   reading it and the tracker treats it as a failure. Fix: ensure the harness
   origin is in the instance's SDK authorized origins (prerequisite #3).
2. **`+auth` vs. tracker credentials.** The proxy is mounted under `+auth`. The
   browser-tracker POST may not carry the SDK's session cross-origin (cookie
   needs `credentials: include` + `Access-Control-Allow-Credentials`). If it
   401s, that is the finding — decide whether the production endpoint relaxes
   auth (EMB-1758) or the tracker is configured to send credentials.
3. **Raw body in the proxy.** The PoC re-encodes the JSON-parsed body. If the
   collector rejects the re-encoded payload, the production endpoint needs true
   raw byte passthrough.
4. **Iglu validation in Micro.** A minimal event may land in `/micro/bad`. That
   still proves transport; tighten the payload only if a clean event is wanted.

## Troubleshooting

`./start.sh` runs a preflight and refuses to start on fatal problems (missing
caddy/node, unset JWT secret, busy ports, missing SDK loader) with a fix inline.
It warns (but continues) if Metabase or Micro aren't reachable. Beyond that:

| Symptom | Likely cause | Fix |
|---|---|---|
| Blank page, no SDK UI | Instance not serving the bundle, or origin not allowlisted | Run `bun run build-hot` in the metabase repo; add `http://csp.localhost:8088` to SDK authorized origins |
| Console: `Refused to ... script-src` for `…/app/embedding-sdk.js` | `script-src` doesn't allow the instance | Already fixed in the Caddyfile; if you edited it, re-add `http://localhost:3000` to `script-src` |
| CORS error on `/auth/sso`, `/api/analytics/snowplow-proxy`, or `/app/fonts/*` (no `Access-Control-Allow-Origin`) | `csp.localhost:8088` not allowlisted — not a loopback host, so not auto-approved | Add `csp.localhost:8088` to SDK authorized origins (prereq #3). Fixes all three at once. Server-side CORS, not the page CSP. |
| Login / SSO error (after CORS is fixed) | JWT secret mismatch, or JWT SSO not enabled | `.env` secret must equal Admin → Auth → JWT signing key; enable JWT SSO |
| Console: `Connecting to 'ws://csp.localhost:8080/ws' violates ... connect-src` | webpack-dev-server HMR socket from `build-hot` | Harmless — HMR only, unrelated to the SDK/telemetry. Ignore, or run a production instance bundle. |
| Proxy POST returns 401 | `+auth` + tracker not sending the session cross-origin | The `+auth` finding (surprise #2) — note it; decide endpoint auth in EMB-1758 |
| Proxy POST 2xx but nothing in Micro | Micro down, or the instance bundle is stale (no telemetry) | Start Micro at `:9090`; ensure `build-hot` recompiled the bundle |
| Event lands in `/micro/bad` not `/micro/good` | Iglu validation (surprise #4) | Fine for transport proof; tighten payload only if needed |
| Build error: `"X" is not exported by ".../main.bundle.js"` | SDK loader stale/missing | Rebuild in metabase repo: `bun run build-embedding-sdk-package`, then `npm run build` in `app/` |
| Baseline button shows NO violation | Page not served via Caddy (CSP missing) | Open `http://csp.localhost:8088` (Caddy), not the Vite dev server |

## Assumed layout

This harness expects the Metabase checkout as a sibling directory:

```
workspace/
  metabase/            # the Metabase repo (built SDK + running instance)
  metabase-sdk-csp/    # this harness
```

The app `file:`-links `../../metabase/resources/embedding-sdk`. If your metabase
checkout is elsewhere, update that path in `app/package.json` and `SDK_DIST` in
`start.sh`.
