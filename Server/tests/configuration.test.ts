import { afterEach, expect, test } from "bun:test";
import { mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseConfiguration } from "../src/configuration.ts";

const directories: string[] = [];
afterEach(async () => {
  for (const directory of directories.splice(0))
    await rm(directory, { recursive: true, force: true });
});
const environment = {
  V07_SERVER_DATA_DIR: "/tmp/v07-config",
  V07_ENGINE_PATH: "/tmp/speech",
  V07_SPEECH_MODEL: "/tmp/speech-model",
  V07_VAD_PATH: "/tmp/vad",
  V07_TEXT_ENGINE_PATH: "/tmp/proof",
  V07_TEXT_MODEL: "/tmp/proof-model",
};

test("CLI overrides environment and uses independent explicit model/data paths", async () => {
  const configuration = await parseConfiguration(["--port", "8392", "--dev"], {
    ...environment,
    V07_SERVER_PORT: "8391",
  });
  expect(configuration).toMatchObject({
    host: "127.0.0.1",
    port: 8392,
    development: true,
    dataDirectory: "/tmp/v07-config",
    inference: { speechHelper: "/tmp/speech", proofModel: "/tmp/proof-model" },
  });
  for (const port of ["0", "65536", "12oops", "1.2", "NaN"])
    await expect(parseConfiguration(["--port", port], environment)).rejects.toThrow("Port");
  await expect(parseConfiguration(["--unknown", "value"], environment)).rejects.toThrow("Unknown");
  await expect(parseConfiguration([], {})).rejects.toThrow("Configure");
});

test("remote listeners require a bounded regular UTF8 token file", async () => {
  await expect(parseConfiguration(["--host", "0.0.0.0"], environment)).rejects.toThrow(
    "requires a token",
  );
  const directory = await mkdtemp(join(tmpdir(), "v07-config-"));
  directories.push(directory);
  const file = join(directory, "token");
  await writeFile(file, `${"x".repeat(32)}\n`);
  const configuration = await parseConfiguration(
    ["--host", "0.0.0.0", "--token-file", file],
    environment,
  );
  expect(configuration.token).toBe("x".repeat(32));
  const link = join(directory, "link");
  await symlink(file, link);
  await expect(parseConfiguration(["--token-file", link], environment)).rejects.toThrow();
  await writeFile(file, "short");
  await expect(
    parseConfiguration(["--host", "0.0.0.0", "--token-file", file], environment),
  ).rejects.toThrow("requires a token");
  await writeFile(file, "x".repeat(4097));
  await expect(parseConfiguration(["--token-file", file], environment)).rejects.toThrow("4096");
  await writeFile(file, "x y");
  await expect(parseConfiguration(["--token-file", file], environment)).rejects.toThrow(
    "whitespace",
  );
});
