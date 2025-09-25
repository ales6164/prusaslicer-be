import {mkdir} from "node:fs/promises";
import {sliceWithPrusaSlicer} from "./index.ts";

const ALLOWED_EXT = new Set([".stl", ".3mf", ".amf", ".obj"]);
const WORKDIR = `${process.env.HOME}/.local/share/prusaslicer-cli`;

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


async function handleSlice(inputFilePath: string) {
    const file = Bun.file(inputFilePath);

    const name = file.name || "model";
    const ext = extOf(name);
    if (!ALLOWED_EXT.has(ext)) return {error: `unsupported extension: ${ext}`}

    const base = randomBase("job");
    const outPath = `${WORKDIR}/${base}.gcode`;

    try {

        await sliceWithPrusaSlicer(inputFilePath, outPath);

        return {
            inPath: inputFilePath,
            outPath,
            base
        }

        //const gcode = await Bun.file(outPath).bytes();

    } catch (err: any) {
        return {error: `error: ${err?.message || String(err)}`}
    }
}

const inputFilePath = await prompt("Input file path: ");
if (inputFilePath) {
    const result = await handleSlice(inputFilePath)
    console.log(result)
} else {
    console.log("No input file path provided. Stopping.")
}