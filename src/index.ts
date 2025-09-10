// Bun 1.1+
// POST /slice  -> multipart form-data with field "file"
// Accepts: .stl, .3mf, .amf, .obj
// Returns: G-code bytes (text/plain) produced by PrusaSlicer CLI via Flatpak

const ALLOWED_EXT = new Set([".stl", ".3mf", ".amf", ".obj"]);
const WORKDIR = `${process.env.HOME}/.local/share/prusaslicer-cli`;
await Bun.mkdir(WORKDIR, { recursive: true });

function extOf(name: string) {
    const i = name.lastIndexOf(".");
    return i >= 0 ? name.slice(i).toLowerCase() : "";
}

function randomBase(prefix: string) {
    return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}

async function sliceWithPrusaSlicer(inputPath: string, outputPath: string) {
    // Use bundled config to avoid depending on user printer profiles
    // You can swap default_fff.ini for your own setup if needed.
    const configPath = `${WORKDIR}/default_fff.ini`;
    await Bun.write(
        configPath,
        await Bun.file(new URL("./default_fff.ini", import.meta.url)).arrayBuffer()
    );

    const args = [
        "run",
        "--command=prusa-slicer",
        "com.prusa3d.PrusaSlicer",
        "--load",
        configPath,
        "--gcode",
        "-o",
        outputPath,
        inputPath
    ];

    const proc = Bun.spawn(["flatpak", ...args], {
        stderr: "pipe",
        stdout: "pipe"
    });

    const [{ success, code }, stderr] = await Promise.all([
        proc.exited,
        proc.stderr!.text()
    ]);

    if (!success || code !== 0) {
        throw new Error(`PrusaSlicer failed (code ${code}): ${stderr}`);
    }
}

async function handleSlice(form: FormData) {
    const file = form.get("file");
    if (!(file instanceof File)) {
        return new Response("field 'file' required", { status: 400 });
    }

    const name = file.name || "model";
    const ext = extOf(name);
    if (!ALLOWED_EXT.has(ext)) {
        return new Response(`unsupported extension: ${ext}`, { status: 400 });
    }

    const base = randomBase("job");
    const inPath = `${WORKDIR}/${base}${ext}`;
    const outPath = `${WORKDIR}/${base}.gcode`;

    try {
        await Bun.write(inPath, await file.arrayBuffer());
        await sliceWithPrusaSlicer(inPath, outPath);

        const gcode = await Bun.file(outPath).bytes();
        return new Response(gcode, {
            status: 200,
            headers: {
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Disposition": `attachment; filename="${base}.gcode"`
            }
        });
    } catch (err: any) {
        return new Response(`error: ${err?.message || String(err)}`, { status: 500 });
    } finally {
        // best-effort cleanup
        try { await Bun.file(inPath).unlink(); } catch {}
        try { await Bun.file(outPath).unlink(); } catch {}
    }
}

const server = Bun.serve({
    port: process.env.PORT ? Number(process.env.PORT) : 3000,
    async fetch(req) {
        const { method, url } = req;
        const u = new URL(url);

        if (method === "GET" && u.pathname === "/") {
            return new Response("OK", { status: 200 });
        }

        if (method === "POST" && u.pathname === "/slice") {
            const ct = req.headers.get("content-type") || "";
            if (!ct.startsWith("multipart/form-data")) {
                return new Response("use multipart/form-data", { status: 415 });
            }
            const form = await req.formData();
            return handleSlice(form);
        }

        return new Response("Not found", { status: 404 });
    }
});

console.log(`listening on http://localhost:${server.port}`);
