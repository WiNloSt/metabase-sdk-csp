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

The JWT provider is reverse-proxied under the same `:8088` origin, so it counts
as `'self'` — exactly how a customer co-locates their auth backend with their app.

## Prerequisites (on the Metabase instance)

JWT SSO is an Enterprise feature, so the local instance needs an EE token.

1. **Metabase running** at `http://localhost:3000` with an EE/premium token.
2. **JWT SSO enabled**: Admin → Settings → Authentication → JWT → enable. Copy
   the value of *"String used by the JWT signing key"* — that is the shared
   secret the auth-server signs with.
3. **Allow the harness origin for the SDK**: Admin → Embedding → Modular
   embedding (SDK) → add `http://localhost:8088` to the authorized origins.
   Without this, cross-origin SDK calls from `:8088` to `:3000` are CORS-blocked
   before telemetry is ever reached.
4. **Snowplow collector for local dev**: the `snowplow-url` setting defaults to
   `http://localhost:9090` (Snowplow Micro) outside prod. Run Snowplow Micro
   there so forwarded events are observable. (See the iglu-schema-registry repo
   for how to run Micro locally.)

## Build & run

### 1. Build the SDK from the Metabase repo (with the EMB-1764 changes)

The app `file:`-links `../../metabase/resources/embedding-sdk`, so build it first
and rebuild after any SDK-side change:

```bash
cd /Users/kelvin/workspace/metabase
bun run build-embedding-sdk-package   # slow; produces resources/embedding-sdk/dist
```

### 2. Start the JWT auth-server

```bash
cd /Users/kelvin/workspace/metabase-sdk-csp/auth-server
npm install
METABASE_JWT_SHARED_SECRET='<paste the JWT signing key>' npm start
# → JWT provider listening on http://localhost:8089/sso/metabase
```

### 3. Build the SDK app

```bash
cd /Users/kelvin/workspace/metabase-sdk-csp/app
npm install
cp .env.example .env   # adjust VITE_DASHBOARD_ID to a dashboard that exists locally
npm run build          # → app/dist
```

### 4. Serve under the strict CSP

```bash
cd /Users/kelvin/workspace/metabase-sdk-csp
caddy run              # serves http://localhost:8088
```

Open <http://localhost:8088> with DevTools (Console + Network) open.

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

## Known surprises this PoC is meant to find

Ranked by likelihood; see the plan's §6 in the Metabase repo
(`.claude/kelvin/2026-05-21-emb-1764-.../01-poc-plan.md`).

1. **CORS / ACAO on the proxy.** The proxy POST is cross-origin (`:8088` → `:3000`).
   If the response lacks `Access-Control-Allow-Origin` for `:8088`, the browser
   blocks reading it and the tracker treats it as a failure. Fix: ensure the
   harness origin is in the instance's SDK authorized origins (prerequisite #3).
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
