import {mkdir} from "node:fs/promises";
import * as path from "node:path";
import * as os from "node:os";


const WORKDIR = `.`;

// Ensure working directory exists (holds temp files and a copied config)
await mkdir(WORKDIR, {recursive: true});

/**
 * Returns lowercase file extension (including dot) or empty string.
 */
export function extOf(name: string) {
    const i = name.lastIndexOf(".");
    return i >= 0 ? name.slice(i).toLowerCase() : "";
}

/**
 * Generates a short unique basename for temp files.
 */
export function randomBase(prefix: string) {
    return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}

/**
 * Handles the POST /slice upload:
 *  - Validates multipart "file" and extension
 *  - Saves input, invokes slicer, streams back G-code as text/plain
 *  - Cleans up temp files regardless of success
 */
export async function handleSlice(inPath: string, outPath: string) {
    const stdout = await sliceWithPrusaSlicer(inPath, outPath);

    return {
        inPath, outPath, stdout
    }
}

/**
 * Runs PrusaSlicer (Flatpak) in headless mode to produce G-code.
 * Writes a bundled generic config into WORKDIR and loads it with --load.
 * Throws on non-zero exit code with captured stderr.
 */
export async function sliceWithPrusaSlicer(inputPath: string, outputPath: string) {
    const args = [
        "prusa-slicer",
        inputPath,
        "--gcode",
        "-o",
        outputPath
    ];

    const proc = Bun.spawn(args, {stderr: "pipe", stdout: "pipe"});
    const [code, stderr, stdout] = await Promise.all([
        proc.exited,
        proc.stderr!.text(),
        proc.stdout!.text()
    ]);

    if (code !== 0) throw new Error(`PrusaSlicer failed (code ${code}): ${stderr}`);

    // Return stdout as text
    return stdout.toString()
}
