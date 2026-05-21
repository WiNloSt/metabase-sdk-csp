// Minimal "customer backend" that signs a Metabase JWT SSO token.
//
// The SDK calls jwtProviderUri (proxied to here as /sso/metabase), gets back
// { jwt }, then exchanges it at the Metabase instance's /auth/sso to establish a
// session. This is the standard Metabase JWT SSO flow — nothing CSP-specific.

import express from "express";
import jwt from "jsonwebtoken";

const PORT = process.env.AUTH_PORT ?? 8089;

// The instance's JWT signing key (Admin > Settings > Authentication > JWT). It's
// masked in the UI, so use a secret you already know (regenerating breaks existing
// JWT integrations using the old one).
const SHARED_SECRET = process.env.METABASE_JWT_SHARED_SECRET;

const USER = {
  email: "csp-harness@example.com",
  first_name: "CSP",
  last_name: "Harness",
  // Optionally map to Metabase groups via group names here.
  // groups: ["Administrators"],
};

if (!SHARED_SECRET) {
  console.error(
    "Missing METABASE_JWT_SHARED_SECRET. Set it in the harness-root .env (copy\n" +
      ".env.example) to the instance's JWT signing key (masked in the UI under\n" +
      "Admin > Settings > Authentication > JWT), then run ./start.sh (or, for this\n" +
      "server alone, npm start).",
  );
  process.exit(1);
}

const app = express();

app.get("/sso/metabase", (_request, response) => {
  const token = jwt.sign(
    { ...USER, exp: Math.round(Date.now() / 1000) + 60 * 10 },
    SHARED_SECRET,
  );
  response.json({ jwt: token });
});

app.listen(PORT, () => {
  console.log(`JWT provider listening on http://localhost:${PORT}/sso/metabase`);
});
