import { afterEach, describe, expect, test } from "bun:test";
import { createHash, randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHTTPServer, isLoopbackAuthority } from "../src/http-server.ts";
import { GenerationService } from "../src/generation-service.ts";
import { validateBody } from "../src/validation.ts";
import { FakeInference } from "./support.ts";

const cleanup: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const close of cleanup.splice(0)) await close();
});
async function fixture(token?: string) {
  const directory = await mkdtemp(join(tmpdir(), "v07-http-"));
  const service = await GenerationService.open(
    { dataDirectory: directory, development: true },
    new FakeInference(),
  );
  const app = createHTTPServer(service, token);
  cleanup.push(async () => {
    await service.shutdown();
    await app.close();
    await rm(directory, { recursive: true, force: true });
  });
  return { app, service, directory };
}

describe("Fastify API contract", () => {
  test("Swift-compatible JSON, binary uploads, NDJSON, artifacts and no-body actions", async () => {
    const { app } = await fixture();
    const original = (await app.inject({ method: "GET", url: "/v1/preferences" })).json();
    original.preferences.keepOriginalAudio = false;
    const preferences = await app.inject({
      method: "PUT",
      url: "/v1/preferences",
      payload: original,
    });
    expect(preferences.statusCode).toBe(200);
    validateBody("PreferencesSnapshot", preferences.json());
    const created = await app.inject({
      method: "POST",
      url: "/v1/generations",
      payload: {
        requestID: randomUUID(),
        device: { id: "http-fixture", name: "Fixture" },
        mode: "test",
      },
    });
    expect(created.statusCode).toBe(201);
    const id: string = created.json().id;
    const pcm = Buffer.alloc(16_000 * 4);
    const uploaded = await app.inject({
      method: "POST",
      url: `/v1/generations/${id}/audio/inference?sequence=0&sampleRate=16000&channels=1`,
      headers: { "content-type": "application/octet-stream" },
      payload: pcm,
    });
    expect(uploaded.statusCode).toBe(200);
    expect(validateBody("AudioChunkReceipt", uploaded.json())).toEqual({
      nextSequence: 1,
      frameCount: 16_000,
    });
    const finished = await app.inject({
      method: "POST",
      url: `/v1/generations/${id}/finish`,
      payload: { inferenceFrames: 16_000 },
    });
    expect(finished.statusCode).toBe(202);
    const events = await app.inject({ method: "GET", url: `/v1/generations/${id}/events` });
    expect(events.headers["content-type"]).toContain("ndjson");
    const records = events.body
      .trim()
      .split("\n")
      .map((line) => validateBody("GenerationRecord", JSON.parse(line)));
    expect(records.at(-1)?.status).toBe("completed");
    expect(records.at(-1)?.finalText).toBe("Hello world.");
    const artifact = await app.inject({
      method: "GET",
      url: `/v1/generations/${id}/artifacts/inference.wav`,
    });
    expect(artifact.statusCode).toBe(200);
    expect(artifact.rawPayload.subarray(0, 4).toString()).toBe("RIFF");
    expect(artifact.rawPayload.subarray(44)).toEqual(pcm);
    const delivered = await app.inject({
      method: "POST",
      url: `/v1/generations/${id}/delivery`,
      payload: { status: "tested", reportedAt: "2026-01-01T00:00:00Z" },
    });
    expect(delivered.statusCode).toBe(200);
    const cancelled = await app.inject({
      method: "POST",
      url: `/v1/generations/${id}/cancel`,
      headers: { "content-type": "application/json" },
    });
    expect(cancelled.statusCode).toBe(200);
    expect(cancelled.json().status).toBe("completed");
    const deleted = await app.inject({
      method: "DELETE",
      url: `/v1/generations/${id}`,
      headers: { "content-type": "application/json" },
    });
    expect(deleted.statusCode).toBe(204);
  });

  test("authentication, Host/Origin policy and errors expose no internal diagnostics", async () => {
    const { app } = await fixture("x".repeat(32));
    expect((await app.inject("/v1/health")).statusCode).toBe(200);
    const rejected = await app.inject("/v1/preferences");
    expect(rejected.statusCode).toBe(401);
    expect(validateBody("APIErrorResponse", rejected.json())).toEqual({
      code: "unauthorized",
      message: "Connect with the server's access token.",
    });
    expect(
      (
        await app.inject({
          url: "/v1/preferences",
          headers: { authorization: `Bearer ${"x".repeat(32)}`, origin: "https://example.com" },
        })
      ).statusCode,
    ).toBe(403);
    const missing = await app.inject({
      url: `/v1/generations/${randomUUID()}`,
      headers: { authorization: `Bearer ${"x".repeat(32)}` },
    });
    expect(missing.statusCode).toBe(404);
    expect(missing.body).not.toContain("/tmp");
    const { app: local } = await fixture();
    expect(
      (await local.inject({ url: "/v1/health", headers: { host: "attacker.example" } })).statusCode,
    ).toBe(403);
    for (const authority of ["localhost", "LOCALHOST:8392", "127.0.0.1:1", "[::1]:65535"])
      expect(isLoopbackAuthority(authority)).toBe(true);
    for (const authority of [
      undefined,
      "localhost:0",
      "localhost:65536",
      "localhost.example",
      "localhost:",
      "localhost:abc",
      "::1",
    ])
      expect(isLoopbackAuthority(authority)).toBe(false);
  });

  test("malformed JSON/query/UUID and excessive bodies are rejected", async () => {
    const { app } = await fixture();
    expect(
      (await app.inject({ method: "POST", url: "/v1/generations", payload: {} })).statusCode,
    ).toBe(400);
    expect(
      (
        await app.inject({
          method: "POST",
          url: "/v1/generations",
          headers: { "content-type": "application/json" },
          payload: "{",
        })
      ).statusCode,
    ).toBe(400);
    expect((await app.inject("/v1/generations/not-a-uuid")).statusCode).toBe(400);
    expect((await app.inject("/v1/generations?limit=1x")).statusCode).toBe(400);
    expect(
      (
        await app.inject({
          method: "POST",
          url: "/v1/generations",
          payload: { large: "x".repeat(262_144) },
        })
      ).statusCode,
    ).toBe(413);
    expect(
      (
        await app.inject({
          method: "POST",
          url: `/v1/generations/${randomUUID()}/audio/inference?sequence=0&sampleRate=16000&channels=1`,
          headers: { "content-type": "application/octet-stream" },
          payload: Buffer.alloc(1_048_577),
        })
      ).statusCode,
    ).toBe(413);
  });

  test("dictionary JSON archive bytes remain exact above the normal JSON body limit", async () => {
    const { app } = await fixture();
    const source = JSON.stringify({ provider: "wispr-flow", padding: "x".repeat(300_000) });
    const response = await app.inject({
      method: "PUT",
      url: "/v1/imports/wispr-flow/dictionary",
      headers: { "content-type": "application/json" },
      payload: source,
    });
    expect(response.statusCode).toBe(200);
    expect(validateBody("WisprFlowDictionaryArchiveReceipt", response.json())).toEqual({
      byteCount: Buffer.byteLength(source),
      sha256: createHash("sha256").update(source).digest("hex"),
    });
  });

  test("imports accept the Swift client's JSON, WAV and PNG media types without parsing bytes", async () => {
    const { app } = await fixture();
    const sourceID = randomUUID();
    const artifacts = [
      {
        filename: "source.json",
        contentType: "application/json",
        body: Buffer.from(
          JSON.stringify({ schemaVersion: 1, provider: "wispr-flow", sourceID, sources: [] }),
        ),
      },
      { filename: "source.wav", contentType: "audio/wav", body: Buffer.from("RIFFxxxxWAVE") },
      {
        filename: "opus.json",
        contentType: "application/json",
        body: Buffer.from('{ "chunks": [] }'),
      },
      {
        filename: "screenshot.png",
        contentType: "image/png",
        body: Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
      },
    ];
    const response = await app.inject({
      method: "POST",
      url: "/v1/imports/wispr-flow",
      payload: {
        sourceID,
        createdAt: "2026-01-01T00:00:00Z",
        finalText: "Imported.",
        rawText: "Imported.",
        variantNames: [],
        artifacts: artifacts.map(({ filename, body }) => ({
          filename,
          byteCount: body.length,
          sha256: createHash("sha256").update(body).digest("hex"),
        })),
      },
    });
    expect(response.statusCode).toBe(201);
    const session = validateBody("WisprFlowImportSession", response.json());
    for (const artifact of artifacts) {
      const uploaded = await app.inject({
        method: "PUT",
        url: `/v1/imports/wispr-flow/${session.id}/artifacts/${artifact.filename}`,
        headers: { "content-type": artifact.contentType },
        payload: artifact.body,
      });
      expect(uploaded.statusCode).toBe(200);
    }
    const completed = await app.inject({
      method: "POST",
      url: `/v1/imports/wispr-flow/${session.id}/complete`,
      headers: { "content-type": "application/json" },
    });
    expect(completed.statusCode).toBe(200);
    const result = validateBody("WisprFlowImportResult", completed.json());
    for (const artifact of artifacts) {
      const stored = await app.inject({
        url: `/v1/generations/${result.record.id}/artifacts/${artifact.filename}`,
      });
      if (artifact.filename !== "source.json") expect(stored.rawPayload).toEqual(artifact.body);
      expect(stored.statusCode).toBe(200);
    }
  });
});
