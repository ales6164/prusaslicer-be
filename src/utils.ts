import {mkdir} from "node:fs/promises";
import * as path from "node:path";
import * as os from "node:os";


const ACME_DIR = process.env.ACME_DIR || "/var/www/acme";
const ALLOWED_EXT = new Set([".stl", ".3mf", ".amf", ".obj"]);
//const WORKDIR = `${process.env.HOME}/.local/share/prusaslicer-cli`;
const WORKDIR = `./.local/share/prusaslicer-cli/temp`;

// Ensure working directory exists (holds temp files and a copied config)
await mkdir(WORKDIR, {recursive: true});


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
 * Handles the POST /slice upload:
 *  - Validates multipart "file" and extension
 *  - Saves input, invokes slicer, streams back G-code as text/plain
 *  - Cleans up temp files regardless of success
 */
export async function handleSlice(form: FormData) {
    const file = form.get("file");
    if (!(file instanceof File)) return {body: {error: "field 'file' required"}, status: 400}

    const name = file.name || "model";
    const ext = extOf(name);
    if (!ALLOWED_EXT.has(ext)) return {body: {error: `unsupported extension: ${ext}`}, status: 400}

    const base = randomBase("job");
    const tmpDir = os.tmpdir()
    const inPath = path.join(tmpDir, `${base}${ext}`);
    const outPath = path.join(tmpDir, `${base}.gcode`);
    let tmpListResult = ""

    try {
        const ok = await Bun.write(inPath, file);
        if (!ok) throw new Error(`error writing file: ${inPath}`)

        if (!await Bun.file(inPath).exists()) {
            throw new Error(`failed to write input file: ${inPath}`)
        }

        tmpListResult = await listFiles(tmpDir)
    } catch (err: any) {
        return {body: {error: `error writing: ${err?.message || String(err)}`, tmpListResult}, status: 500}
    }

    try {
        const gcode = await sliceWithPrusaSlicer(inPath);

        return {
            body: {
                inPath, outPath, base, tmpListResult, gcode
            },
            status: 200,
        }

        //const gcode = await Bun.file(outPath).bytes();

    } catch (err: any) {
        return {body: {error: `error: ${err?.message || String(err)}`, tmpListResult}, status: 500}
    }
}

async function listFiles(dir: string) {
    const proc = Bun.spawn(["ls", "-l", "-a", dir]/*, {
        stdin: await fetch(
            "https://raw.githubusercontent.com/oven-sh/bun/main/examples/hashing.js",
        ),
    }*/);

    return await proc.stdout.text();
}

/**
 * Runs PrusaSlicer (Flatpak) in headless mode to produce G-code.
 * Writes a bundled generic config into WORKDIR and loads it with --load.
 * Throws on non-zero exit code with captured stderr.
 */
export async function sliceWithPrusaSlicer(inputPath: string) {
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
        "flatpak",
        "run",
        "--command=prusa-slicer",
        "com.prusa3d.PrusaSlicer",
        /*"--load",
        configPath,*/
        "--gcode",
        inputPath
    ];

    const proc = Bun.spawn(args, {stderr: "pipe"});
    const [code, stderr] = await Promise.all([proc.exited, proc.stderr!.text()]);

    if (code !== 0) throw new Error(`PrusaSlicer failed (code ${code}): ${stderr} | ran: Bun.spawn([${args.join(" ")}], {stderr: "pipe", stdout: "pipe"})`);

    return await proc.stdout.text()
}


/**
 * Serves ACME HTTP-01 tokens from ACME_DIR.
 * If the path is not an ACME challenge path, returns null.
 */
export async function maybeServeAcme(u: URL): Promise<Response | null> {
    if (!u.pathname.startsWith("/.well-known/acme-challenge/")) return null;
    const token = u.pathname.split("/").pop()!;
    if (!token || token.includes("..")) return new Response("bad token", {status: 400});

    const f = `${ACME_DIR}/${token}`;
    try {
        const body = await Bun.file(f).text();
        return new Response(body, {status: 200, headers: {"Content-Type": "text/plain"}});
    } catch {
        return new Response("not found", {status: 404});
    }
}


/**
 * Main app fetch handler used by HTTPS server (and HTTP when TLS disabled).
 * Routes:
 *   GET  /                                   -> "OK"
 *   POST /slice                              -> returns G-code
 *   GET  /.well-known/acme-challenge/<token> -> ACME token
 */
export async function appFetch(req: Request) {
    const u = new URL(req.url);

    const headers = {
        "Access-Control-Allow-Origin": "*", // or specific origin
        "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Accept, Content-Type, Origin, Referer, Sec-Fetch-Dest, Sec-Fetch-Mode, Sec-Fetch-Site, User-Agent"
    };

    // Handle preflight OPTIONS request
    if (req.method === "OPTIONS") {
        return new Response(null, {status: 204, headers});
    }

    // ACME is available on both HTTP and HTTPS listeners
    const acme = await maybeServeAcme(u);
    if (acme) return acme;

    if (req.method === "GET" && u.pathname === "/") {
        return new Response(WORKDIR, {status: 200, headers});
    }

    if (req.method === "POST" && u.pathname === "/slice") {
        const ct = req.headers.get("content-type") || "";
        if (!ct.startsWith("multipart/form-data"))
            return new Response("use multipart/form-data", {status: 415, headers});
        const form = await req.formData();
        const sliced = await handleSlice(form);

        return new Response(JSON.stringify(sliced.body), {
            status: sliced.status,
            headers: {
                "Content-Type": "application/json; charset=utf-8",
                ...headers,
                /*"Content-Disposition": `attachment; filename="${base}.gcode"`*/
            }
        });
    }

    return new Response("Not found", {status: 404, headers});
}