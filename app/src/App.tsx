import {
  InteractiveDashboard,
  MetabaseProvider,
  defineMetabaseAuthConfig,
} from "@metabase/embedding-sdk-react";

const metabaseInstanceUrl =
  import.meta.env.VITE_METABASE_INSTANCE_URL ?? "http://localhost:3000";

// A dashboard id that exists on your local instance (the sample database's
// dashboard is usually 1). Mounting any SDK component is enough to make the
// provider initialize and fire the PoC telemetry event.
const dashboardId = Number(import.meta.env.VITE_DASHBOARD_ID ?? 1);

// The collector the page CSP does NOT allow. Used only by the baseline button to
// prove a direct POST is blocked. Matches the local dev snowplow-url default.
const collectorUrl =
  import.meta.env.VITE_COLLECTOR_URL ?? "http://localhost:9090";

// JWT SSO. jwtProviderUri is same-origin (Caddy reverse-proxies /sso/metabase to
// the auth-server), so it stays inside connect-src 'self'.
const authConfig = defineMetabaseAuthConfig({
  metabaseInstanceUrl,
  preferredAuthMethod: "jwt",
  jwtProviderUri: "/sso/metabase",
});

// Baseline: a raw POST straight to the collector. Under the strict CSP this must
// throw a console violation ("Refused to connect ... violates connect-src") and
// never hit the network — the exact problem the proxy works around.
const fireDirectCollectorPost = () => {
  fetch(`${collectorUrl}/com.snowplowanalytics.snowplow/tp2`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ schema: "baseline", data: [] }),
  }).catch((error) => console.error("direct collector POST failed:", error));
};

export const App = () => (
  <div style={{ padding: 16, fontFamily: "system-ui, sans-serif" }}>
    <h1>Metabase SDK — strict-CSP telemetry harness</h1>
    <p>
      This page runs under a strict CSP whose <code>connect-src</code> allows the
      Metabase instance but NOT the Snowplow collector. The SDK should still get
      one telemetry event to the collector by routing through the instance proxy.
    </p>
    <p>
      <button onClick={fireDirectCollectorPost}>
        Baseline: fire direct collector POST (expect CSP block)
      </button>
    </p>
    <MetabaseProvider authConfig={authConfig}>
      <InteractiveDashboard dashboardId={dashboardId} />
    </MetabaseProvider>
  </div>
);
