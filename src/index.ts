// Bun 1.1+
//
// HTTPS + HTTP redirect + ACME route + /slice endpoint.
// - Serves HTTP on HTTP_PORT for ACME and redirects to HTTPS when enabled.
// - Serves HTTPS on PORT when HTTPS=1 and certificates are present.
// - Slices uploaded models using PrusaSlicer Flatpak CLI and returns G-code.
//
// Env vars:
//   PORT=443                    # HTTPS listener port when HTTPS=1 (default 8080 if HTTPS!=1)
//   HTTP_PORT=80                # HTTP listener port for ACME + redirect (default 80)
//   HTTPS=1                     # enable TLS when "1"
//   DOMAIN=example.com          # used to derive default cert paths if TLS_CERT/TLS_KEY not set
//   TLS_CERT=/etc/letsencrypt/live/<domain>/fullchain.pem
//   TLS_KEY=/etc/letsencrypt/live/<domain>/privkey.pem
//   ACME_DIR=/var/www/acme       # webroot for HTTP-01 challenge files
//
// API:
//   GET  /                                   -> "OK"
//   POST /slice  multipart/form-data field "file" with .stl|.3mf|.amf|.obj -> G-code
//   GET  /.well-known/acme-challenge/<token> -> serves ACME token from ACME_DIR
//
// Notes:
// - PrusaSlicer is executed via Flatpak: `flatpak run --command=prusa-slicer com.prusa3d.PrusaSlicer`
// - A minimal FFF config `default_fff.ini` is written into WORKDIR and loaded for slicing.

import { mkdir } from "node:fs/promises";
import {appFetch, maybeServeAcme} from "./utils.ts";



/**
 * HTTP listener:
 *  - Always listens on HTTP_PORT.
 *  - If HTTPS is enabled, serves ACME then 301-redirects to https://
 *  - If HTTPS is disabled, serves the app directly.
 */
const HTTPS_ENABLED = process.env.HTTPS === "1";
const HTTP_PORT = Number(process.env.HTTP_PORT || 80);

Bun.serve({
    port: HTTP_PORT,
    async fetch(req) {
        const u = new URL(req.url);

        // Serve ACME tokens without redirect.
        const acme = await maybeServeAcme(u);
        if (acme) return acme;

        if (HTTPS_ENABLED) {
            // Redirect all other HTTP traffic to HTTPS.
            const host = req.headers.get("host") || "";
            const location = `https://${host}${u.pathname}${u.search}`;
            return new Response(null, { status: 301, headers: { Location: location } });
        }

        // TLS disabled -> serve the app on plain HTTP.
        return appFetch(req);
    }
});

console.log(`http listening on :${HTTP_PORT} (acme${HTTPS_ENABLED ? " + redirect" : " + app"})`);

/**
 * HTTPS listener:
 *  - When HTTPS=1, binds to PORT with provided cert and key.
 *  - Cert/key resolved from TLS_CERT/TLS_KEY or derived from DOMAIN.
 *  - When HTTPS!=1, starts an HTTP app server on PORT (dev mode).
 */
const PORT = Number(process.env.PORT || (HTTPS_ENABLED ? 443 : 8080));

if (HTTPS_ENABLED) {
    const DOMAIN = process.env.DOMAIN || "";
    const CERT = process.env.TLS_CERT || (DOMAIN ? `/etc/letsencrypt/live/${DOMAIN}/fullchain.pem` : "");
    const KEY = process.env.TLS_KEY || (DOMAIN ? `/etc/letsencrypt/live/${DOMAIN}/privkey.pem` : "");

    if (!CERT || !KEY) {
        throw new Error("HTTPS=1 requires TLS_CERT and TLS_KEY or DOMAIN to derive default paths.");
    }

    Bun.serve({
        port: PORT,
        fetch: appFetch,
        tls: {
            cert: Bun.file(CERT),
            key: Bun.file(KEY)
        }
    });

    console.log(`https listening on :${PORT}`);
} else {
    // Dev fallback: serve the app over HTTP on PORT.
    Bun.serve({ port: PORT, fetch: appFetch });
    console.log(`http (app) listening on :${PORT}`);
}
