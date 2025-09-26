import {extOf, randomBase} from "./utils.ts";
import {relative, isAbsolute, resolve, join} from "node:path";
import {realpath, readFile, stat, mkdir} from "node:fs/promises";
import {tmpdir} from "node:os";
import {sliceWithPrusaSlicer} from "./slicer.ts";
import {getPriceAndTimeEstimate} from "./estimates.ts";

//const WORKDIR = `.`;
const HTTP_PORT = Number(process.env.HTTP_PORT || 80);
//const ALLOWED_EXT = new Set([".stl", ".3mf", ".amf", ".obj"]);
const ALLOWED_EXT = new Set([".stl", ".3mf", ".amf", ".obj", ".step", ".stp", ".ste"]);

// TODO: add .step podporo

// Ensure working directory exists (holds temp files and a copied config)
//await mkdir(WORKDIR, {recursive: true});

async function appFetch(req: Request) {
    const u = new URL(req.url);

    const headers = {
        "Access-Control-Allow-Origin": "*", // or specific origin
        "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Accept, Content-Type, Origin, Referer, Sec-Fetch-Dest, Sec-Fetch-Mode, Sec-Fetch-Site, User-Agent"
    };

    // Handle preflight OPTIONS request
    if (req.method === "OPTIONS") return new Response(null, {status: 204, headers});

    // Handle get gcode
    if (req.method === "GET" && u.pathname === "/") {
        const uploadId = u.searchParams.get("id");
        if (!uploadId) return new Response("missing id param", {status: 400, headers});

        const uploadMetaPath = join(tmpdir(), `${uploadId}.json`);

        const baseTmp = await realpath(tmpdir());
        // If user passed relative path, resolve it *under* tmpdir. If absolute, keep it.
        const candidate = isAbsolute(uploadMetaPath) ? uploadMetaPath : resolve(baseTmp, uploadMetaPath);

        // Canonicalize both sides to defeat symlinks
        let real;
        try {
            // Ensure file exists and is a regular file
            const s = await stat(candidate);
            if (!s.isFile()) return new Response("not found", {status: 404, headers});
            real = await realpath(candidate);
        } catch {
            return new Response("not found", {status: 404, headers});
        }

        // Enforce file is inside tmpdir
        const rel = relative(baseTmp, real);
        if (rel.startsWith("..") || isAbsolute(rel)) {
            return new Response("not found", {status: 404, headers});
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

        const form = await req.formData(),
            file = form.get("file");
        if (!(file instanceof File)) return new Response("no file", {status: 400, headers});

        const name = file.name || "model",
            ext = extOf(name);
        // 100 MB limit
        if (file.size > 100 * 1024 * 1024) return new Response("request too big", {status: 413, headers});
        if (!ALLOWED_EXT.has(ext)) return new Response(`unsupported extension: ${ext}`, {status: 400, headers});

        const base = randomBase("job"),
            tmpDir = tmpdir(),
            uploadId = crypto.randomUUID(),
            uploadMetaPath = join(tmpDir, `${uploadId}.json`),
            inPath = join(tmpDir, `${base}${ext}`),
            outPath = join(tmpDir, `${base}.gcode`);

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
            const stdout = await sliceWithPrusaSlicer(inPath, outPath);
            let estimates  = null

            try {
                estimates = await getPriceAndTimeEstimate(outPath)
            } catch (err: any) {
                return new Response(`error getting price estimate: ${err?.message || String(err)}`, {status: 500, headers});
            }

            const clientResponse = {
                uploadId,
                previewUrl: null,
                priceEstimate: estimates?.priceEstimate,
                timeEstimate: estimates?.timeEstimate,
            }

            try {
                // Write meta
                const meta = {
                    requestMeta: {
                        name,
                        ext,
                        size: file.size,
                        uploadId,
                    },
                    createdAt: Date.now(),
                    originalFilePath: inPath,
                    gCodePath: outPath,
                    clientResponse,
                    sliceResult: {
                        inPath,
                        outPath,
                        stdout,
                    },
                    estimates
                }
                const ok = await Bun.write(uploadMetaPath, JSON.stringify(meta));
                if (!ok) return new Response("failed to write to database", {status: 400, headers});
                if (!await Bun.file(inPath).exists()) return new Response("database entry does not exist after writing", {
                    status: 500,
                    headers
                });
            } catch (err: any) {
                return new Response(`error writing database entry: ${err?.message || String(err)}`, {status: 500, headers});
            }

            return new Response(JSON.stringify(clientResponse), {
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
    idleTimeout: 255,
    async fetch(req) {
        return appFetch(req);
    }
});

console.log(`http listening on: ${HTTP_PORT}`);