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

const ALLOWED_EXT = new Set([".stl", ".3mf", ".amf", ".obj"]);
const WORKDIR = `${process.env.HOME}/.local/share/prusaslicer-cli`;
const ACME_DIR = process.env.ACME_DIR || "/var/www/acme";

// Ensure working directory exists (holds temp files and a copied config)
await mkdir(WORKDIR, { recursive: true });

/**
 * Returns lowercase file extension (including dot) or empty string.
 */
function extOf(name: string) {
    const i = name.lastIndexOf(".");
    return i >= 0 ? name.slice(i).toLowerCase() : "";
}

/**
 * Generates a short unique basename for temp files.
 */
function randomBase(prefix: string) {
    return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}

/**
 * Runs PrusaSlicer (Flatpak) in headless mode to produce G-code.
 * Writes a bundled generic config into WORKDIR and loads it with --load.
 * Throws on non-zero exit code with captured stderr.
 */
async function sliceWithPrusaSlicer(inputPath: string, outputPath: string) {
    /*const configPath = `${WORKDIR}/default_fff.ini`;

    // Write bundled config next to temp files.
    await Bun.write(
        configPath,
        await Bun.file(new URL("./default_fff.ini", import.meta.url)).arrayBuffer()
    );*/

    /*
      "--export-gcode", tmpPath,
                "--output", tmpSlicedPath
     */

    const args = [
        "run",
        "--command=prusa-slicer",
        "com.prusa3d.PrusaSlicer",
        /*"--load",
        configPath,*/
        "--gcode",
        "-o",
        outputPath,
        inputPath
    ];

    const proc = Bun.spawn(["flatpak", ...args], { stderr: "pipe", stdout: "pipe" });
    const [code, stderr] = await Promise.all([proc.exited, proc.stderr!.text()]);

    if (code !== 0) throw new Error(`PrusaSlicer failed (code ${code}): ${stderr}`);
}

/**
 * Handles the POST /slice upload:
 *  - Validates multipart "file" and extension
 *  - Saves input, invokes slicer, streams back G-code as text/plain
 *  - Cleans up temp files regardless of success
 */
async function handleSlice(form: FormData) {
    const file = form.get("file");
    if (!(file instanceof File)) return {body: {error: "field 'file' required"}, status: 400}

    const name = file.name || "model";
    const ext = extOf(name);
    if (!ALLOWED_EXT.has(ext)) return {body: {error: `unsupported extension: ${ext}`}, status: 400}

    const base = randomBase("job");
    const inPath = `${WORKDIR}/${base}${ext}`;
    const outPath = `${WORKDIR}/${base}.gcode`;

    try {
        await Bun.write(inPath, await file.arrayBuffer());
        await sliceWithPrusaSlicer(inPath, outPath);

        return {
            body: {
                inPath, outPath, base
            },
            status: 200,
        }

        //const gcode = await Bun.file(outPath).bytes();

    } catch (err: any) {
        return {body: {error: `error: ${err?.message || String(err)}`}, status: 500}
    } finally {
        try { await Bun.file(inPath).unlink(); } catch {}
        try { await Bun.file(outPath).unlink(); } catch {}
    }
}

/**
 * Serves ACME HTTP-01 tokens from ACME_DIR.
 * If the path is not an ACME challenge path, returns null.
 */
async function maybeServeAcme(u: URL): Promise<Response | null> {
    if (!u.pathname.startsWith("/.well-known/acme-challenge/")) return null;
    const token = u.pathname.split("/").pop()!;
    if (!token || token.includes("..")) return new Response("bad token", { status: 400 });

    const f = `${ACME_DIR}/${token}`;
    try {
        const body = await Bun.file(f).text();
        return new Response(body, { status: 200, headers: { "Content-Type": "text/plain" } });
    } catch {
        return new Response("not found", { status: 404 });
    }
}

/**
 * Main app fetch handler used by HTTPS server (and HTTP when TLS disabled).
 * Routes:
 *   GET  /                                   -> "OK"
 *   POST /slice                              -> returns G-code
 *   GET  /.well-known/acme-challenge/<token> -> ACME token
 */
async function appFetch(req: Request) {
    const u = new URL(req.url);

    const headers = {
        "Access-Control-Allow-Origin": "*", // or specific origin
        "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Accept, Content-Type, Origin, Referer, Sec-Fetch-Dest, Sec-Fetch-Mode, Sec-Fetch-Site, User-Agent"
    };

    // Handle preflight OPTIONS request
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers });
    }

    // ACME is available on both HTTP and HTTPS listeners
    const acme = await maybeServeAcme(u);
    if (acme) return acme;

    if (req.method === "GET" && u.pathname === "/") {
        return new Response("OK", { status: 200, headers });
    }

    if (req.method === "POST" && u.pathname === "/slice") {
        const ct = req.headers.get("content-type") || "";
        if (!ct.startsWith("multipart/form-data"))
            return new Response("use multipart/form-data", { status: 415, headers });
        const form = await req.formData();
        const sliced =  await handleSlice(form);

        return new Response(JSON.stringify(sliced.body), {
            status: sliced.status,
            headers: {
                "Content-Type": "application/json; charset=utf-8",
                ...headers,
                /*"Content-Disposition": `attachment; filename="${base}.gcode"`*/
            }
        });
    }

    return new Response("Not found", { status: 404, headers });
}

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
