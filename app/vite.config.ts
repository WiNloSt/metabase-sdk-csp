import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// Built output (app/dist) is served by Caddy under the strict CSP, NOT by Vite's
// dev server — Vite dev injects inline scripts and an HMR websocket that the
// strict CSP would block, which would muddy the test. Always: `npm run build`,
// then let Caddy serve the static bundle.
export default defineConfig({
  plugins: [react()],
  // Read the single harness-root .env (one file to configure everything). Only
  // VITE_-prefixed vars are exposed to the browser, so the JWT secret stays out.
  envDir: "..",
  build: {
    // Keep asset URLs root-relative so Caddy's file_server resolves them.
    assetsDir: "assets",
    commonjsOptions: {
      // The SDK package is a CJS webpack bundle that externalizes React as
      // `e.exports = require("react")`. It's symlinked (file: dep), so its
      // realpath is outside node_modules and rollup's commonjs plugin skips it
      // by default — leaving raw `require()` to blow up in the browser. Include
      // the SDK's real path so those requires get rewritten to imports.
      include: [/node_modules/, /resources[/\\]embedding-sdk/],
      transformMixedEsModules: true,
    },
  },
});
