import { expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { standaloneBuildSettings } from "../scripts/standalone-build-settings.ts";

test("production standalone manifest runs the embedded correction worker", async () => {
  const directory = await mkdtemp(join(tmpdir(), "v07-worker-standalone-"));
  const executable = join(directory, "correction-worker-probe");
  try {
    const built = await Bun.build({
      ...standaloneBuildSettings(
        resolve(import.meta.dirname, "fixtures/correction-worker-standalone.ts"),
      ),
      compile: { outfile: executable, autoloadDotenv: false, autoloadBunfig: false },
    });
    expect(built.success).toBe(true);
    const result = Bun.spawnSync([executable]);
    expect(result.exitCode).toBe(0);
    expect(result.stdout.toString().trim()).toBe("Compiled correction worker parity passed.");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}, 15_000);
