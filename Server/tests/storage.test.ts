import { expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readRegularFile } from "../src/storage.ts";

test("regular archive reads reject a FIFO without blocking", async () => {
  const directory = await mkdtemp(join(tmpdir(), "v07-storage-test-"));
  try {
    const fifo = join(directory, "metadata.json");
    const process = Bun.spawn(["mkfifo", fifo], { stdout: "ignore", stderr: "ignore" });
    expect(await process.exited).toBe(0);
    await expect(readRegularFile(fifo, 1_048_576)).rejects.toMatchObject({
      code: "invalid_archive",
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}, 1000);
