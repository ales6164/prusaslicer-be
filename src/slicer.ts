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
