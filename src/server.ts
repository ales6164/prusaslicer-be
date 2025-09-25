import {extOf, handleSlice, randomBase} from "./utils.ts";
import {extname, relative, isAbsolute, resolve, join} from "node:path";
import {realpath, readFile, stat} from "node:fs/promises";
import {tmpdir} from "node:os";

const HTTP_PORT = Number(process.env.HTTP_PORT || 80);
const ALLOWED_EXT = new Set([".stl", ".3mf", ".amf", ".obj"]);

async function appFetch(req: Request) {
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

    // Handle get gcode
    if (req.method === "GET" && u.pathname === "/") {
        const fp = u.searchParams.get("path");
        if (!fp) return new Response("missing ?path", {status: 400, headers});

        // Must end with .gcode
        if (extname(fp).toLowerCase() !== ".gcode") {
            return new Response("invalid extension", {status: 400, headers});
        }

        const baseTmp = await realpath(tmpdir());
        // If user passed relative path, resolve it *under* tmpdir. If absolute, keep it.
        const candidate = isAbsolute(fp) ? fp : resolve(baseTmp, fp);

        // Canonicalize both sides to defeat symlinks
        let real;
        try {
            // Ensure file exists and is a regular file
            const s = await stat(candidate);
            if (!s.isFile()) return new Response("not a file", {status: 400, headers});
            real = await realpath(candidate);
        } catch {
            return new Response("not found", {status: 404, headers});
        }

        // Enforce file is inside tmpdir
        const rel = relative(baseTmp, real);
        if (rel.startsWith("..") || isAbsolute(rel)) {
            return new Response("forbidden path", {status: 403, headers});
        }

        // Read and return
        const data = await readFile(real);
        return new Response(data, {
            status: 200,
            headers: {
                ...headers,
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Disposition": `inline; filename="${rel.split("/").pop()}"`,
            },
        });
    }

    if (req.method === "POST" && u.pathname === "/slice") {
        const ct = req.headers.get("content-type") || "";
        if (!ct.startsWith("multipart/form-data"))
            return new Response("use multipart/form-data", {status: 415, headers});
        const form = await req.formData();

        const file = form.get("file");
        if (!(file instanceof File)) return new Response("no file", {status: 400, headers});

        const name = file.name || "model";
        const ext = extOf(name);
        if (!ALLOWED_EXT.has(ext)) return new Response(`unsupported extension: ${ext}`, {status: 400, headers});

        const base = randomBase("job");
        const tmpDir = tmpdir()
        const inPath = join(tmpDir, `${base}${ext}`);
        const outPath = join(tmpDir, `${base}.gcode`);

        try {
            const ok = await Bun.write(inPath, file);
            if (!ok) return new Response("failed to write input file", {status: 400, headers});
            if (!await Bun.file(inPath).exists()) return new Response("input file does not exist after writing", {
                status: 500,
                headers
            });
        } catch (err: any) {
            return new Response(`error writing input file: ${err?.message || String(err)}`, {status: 500, headers});
        }

        try {
            const result = await handleSlice(inPath, outPath);

            return new Response(JSON.stringify(result), {
                status: 200,
                headers: {
                    "Content-Type": "application/json; charset=utf-8",
                    ...headers,
                    /*"Content-Disposition": `attachment; filename="${base}.gcode"`*/
                }
            });
        } catch (err: any) {
            return new Response(`slicing error: ${err?.message || String(err)}`, {status: 500, headers});
        }
    }

    return new Response("not found", {status: 404, headers});
}

Bun.serve({
    port: HTTP_PORT,
    idleTimeout: 60 * 20, // 20 minutes
    async fetch(req) {
        return appFetch(req);
    }
});

console.log(`http listening on: ${HTTP_PORT}`);