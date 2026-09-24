import { strict as assert } from "node:assert";
import { createHash, randomUUID } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const executableIndex = process.argv.indexOf("--executable");
const executable = resolve(
  executableIndex >= 0 ? process.argv[executableIndex + 1]! : "build/server/v07-server",
);
const directory = await mkdtemp(join(tmpdir(), "v07-compiled-smoke-"));
const listener = createServer();
await new Promise<void>((resolve) => listener.listen(0, "127.0.0.1", resolve));
const address = listener.address();
if (!address || typeof address === "string")
  throw new Error("Could not reserve a smoke-test port.");
await new Promise<void>((resolve, reject) =>
  listener.close((error) => (error ? reject(error) : resolve())),
);
const port = address.port;
const args = [
  "--host",
  "127.0.0.1",
  "--port",
  String(port),
  "--data-dir",
  join(directory, "data"),
  "--speech-helper",
  join(directory, "missing-helper"),
  "--speech-model",
  join(directory, "missing-model"),
  "--vad-model",
  join(directory, "missing-vad"),
  "--proof-helper",
  join(directory, "missing-proof"),
  "--proof-model",
  join(directory, "missing-proof-model"),
  "--dev",
];
const child = Bun.spawn([executable, ...args], { stdout: "ignore", stderr: "pipe" });
const root = `http://127.0.0.1:${port}`;
async function json(path: string, method = "GET", body?: unknown, expected = 200) {
  const response = await fetch(root + path, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  assert.equal(response.status, expected, `${path}: ${await response.clone().text()}`);
  return response.status === 204 ? undefined : await response.json();
}
try {
  const deadline = Date.now() + 15_000;
  while (true) {
    try {
      if ((await fetch(`${root}/v1/health`)).ok) break;
    } catch {
      /* Wait only for this child. */
    }
    if (child.exitCode !== null || Date.now() > deadline)
      throw new Error(`Compiled server did not start: ${await new Response(child.stderr).text()}`);
    await Bun.sleep(25);
  }
  const health = await json("/v1/health");
  assert.equal(health.apiVersion, 1);
  assert.equal(health.isDev, true);
  assert.equal(health.ready, false);
  const preferences = await json("/v1/preferences");
  preferences.preferences.keepOriginalAudio = false;
  const saved = await json("/v1/preferences", "PUT", preferences);
  assert.equal(saved.revision, preferences.revision + 1);
  await json("/v1/preferences", "PUT", preferences, 409);
  await json(
    "/v1/generations",
    "POST",
    {
      requestID: randomUUID(),
      device: { id: "compiled-smoke", name: "Compiled smoke" },
      mode: "test",
    },
    503,
  );
  const sourceID = randomUUID();
  const source = Buffer.from(
    JSON.stringify({ schemaVersion: 1, provider: "wispr-flow", sourceID, sources: [] }),
  );
  const session = await json(
    "/v1/imports/wispr-flow",
    "POST",
    {
      sourceID,
      createdAt: "2026-01-01T00:00:00Z",
      finalText: "Compiled server import.",
      rawText: "Compiled server import.",
      variantNames: [],
      artifacts: [
        {
          filename: "source.json",
          byteCount: source.length,
          sha256: createHash("sha256").update(source).digest("hex"),
        },
      ],
    },
    201,
  );
  const uploaded = await fetch(
    `${root}/v1/imports/wispr-flow/${session.id}/artifacts/source.json`,
    { method: "PUT", headers: { "Content-Type": "application/octet-stream" }, body: source },
  );
  assert.equal(uploaded.status, 200, await uploaded.text());
  const result = await json(`/v1/imports/wispr-flow/${session.id}/complete`, "POST");
  assert.equal(result.record.finalText, "Compiled server import.");
  const known = await json("/v1/imports/wispr-flow/known", "POST", { sourceIDs: [sourceID] });
  assert.deepEqual(known.knownSourceIDs, [sourceID]);
  const events = await fetch(`${root}/v1/generations/${result.record.id}/events`);
  assert.equal(JSON.parse((await events.text()).trim()).status, "completed");
  await json(`/v1/generations/${result.record.id}`, "DELETE", undefined, 204);
  const blocked = await fetch(root + "/v1/health", { headers: { Origin: "https://example.com" } });
  assert.equal(blocked.status, 403);
  console.log(
    "Compiled server HTTP, archive, import, streaming and unavailable-model smoke passed.",
  );
} finally {
  child.kill("SIGTERM");
  const forced = setTimeout(() => child.kill("SIGKILL"), 3000);
  await child.exited;
  clearTimeout(forced);
  await rm(directory, { recursive: true, force: true });
}
