import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// Built output (app/dist) is served by Caddy under the strict CSP, NOT by Vite's
// dev server — Vite dev injects inline scripts and an HMR websocket that the
// strict CSP would block, which would muddy the test. Always: `npm run build`,
// then let Caddy serve the static bundle.
export default defineConfig({
  plugins: [react()],
  build: {
    // Keep asset URLs root-relative so Caddy's file_server resolves them.
    assetsDir: "assets",
  },
});
