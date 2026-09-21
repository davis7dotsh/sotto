import { afterEach, describe, expect, test } from "bun:test";
import { createHash, randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import WebSocket from "ws";
import { GenerationService } from "../src/generation-service.ts";
import { createHTTPServer } from "../src/http-server.ts";
import type { DictionaryEntry, PreferencesSnapshot } from "../src/api.ts";
import {
  encodeRecordingAudioMessage,
  MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES,
  MAXIMUM_RECORDING_HEADER_BYTES,
  MAXIMUM_RECORDING_MESSAGE_BYTES,
  RECORDING_WS_PROTOCOL,
  type RecordingAudioHeader,
  type RecordingServerMessage,
  type RecordingSnapshot,
} from "../src/recording-contract.ts";
import { registerRecordingRoutes } from "../src/recording-routes.ts";
import { RecordingService } from "../src/recording-service.ts";
import { FakeInference } from "./support.ts";
import { standaloneBuildSettings } from "../scripts/standalone-build-settings.ts";

const cleanup: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const close of cleanup.splice(0).reverse()) await close();
});

async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "sotto-recording-routes-"));
  const generations = await GenerationService.open(
    { dataDirectory: directory, development: true },
    new FakeInference(),
  );
  const service = await RecordingService.open(
    { dataDirectory: directory, development: true },
    new FakeInference(),
    { getPreferences: () => generations.getPreferences() },
  );
  const token = "recording-test-token";
  const headers = { authorization: `Bearer ${token}` };
  const app = createHTTPServer(generations, token);
  registerRecordingRoutes(app, service);
  const preferences = await generations.getPreferences();
  preferences.preferences.keepOriginalAudio = false;
  await generations.updatePreferences(preferences);
  const address = await app.listen({ port: 0, host: "127.0.0.1" });
  cleanup.push(async () => {
    await app.close();
    await service.shutdown();
    await generations.shutdown();
    await rm(directory, { recursive: true, force: true });
  });
  const created = await app.inject({
    method: "POST",
    url: "/v2/recordings",
    headers,
    payload: {
      requestID: randomUUID(),
      device: { id: "stream-test", name: "Fixture" },
      mode: "test",
    },
  });
  expect(created.statusCode).toBe(201);
  const snapshot: RecordingSnapshot = created.json();
  return {
    app,
    service,
    headers,
    snapshot,
    url: `${address.replace("http:", "ws:")}/v2/recordings/${snapshot.id}/stream`,
  };
}

async function connect(url: string, headers: Record<string, string>) {
  const socket = new WebSocket(url, RECORDING_WS_PROTOCOL, { headers });
  const messages: RecordingServerMessage[] = [];
  let wake: (() => void) | undefined;
  socket.on("message", (data) => {
    messages.push(JSON.parse(data.toString()));
    wake?.();
  });
  socket.on("error", () => {});
  cleanup.push(async () => {
    if (socket.readyState === WebSocket.CLOSED) return;
    const done = new Promise<void>((resolve) => socket.once("close", () => resolve()));
    socket.terminate();
    await done;
  });
  await new Promise<void>((resolve, reject) => {
    socket.once("open", () => resolve());
    socket.once("error", reject);
  });
  const next = async <Type extends RecordingServerMessage["type"]>(type: Type) => {
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline) {
      const index = messages.findIndex((message) => message.type === type);
      if (index >= 0)
        return messages.splice(index, 1)[0] as RecordingServerMessage & { type: Type };
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, 50);
        wake = () => {
          clearTimeout(timer);
          resolve();
        };
      });
      wake = undefined;
    }
    throw new Error(`Timed out waiting for WebSocket ${type}.`);
  };
  return { socket, next };
}

function audio(
  epoch: number,
  runID: string,
  sequence = 0,
  firstFrame = 0,
  frames = 16_000,
  pcm = Buffer.alloc(frames * 4),
) {
  const header: RecordingAudioHeader = {
    type: "audio",
    epoch,
    runID,
    kind: "inference",
    sequence,
    firstFrame,
    format: { sampleRate: 16_000, channels: 1 },
    frameCount: frames,
    sha256: createHash("sha256").update(pcm).digest("hex"),
  };
  const encoded = encodeRecordingAudioMessage(header, pcm);
  if (!encoded.ok) throw new Error(encoded.error.message);
  return encoded.value;
}

async function rejected(
  url: string,
  headers: Record<string, string>,
  protocol = RECORDING_WS_PROTOCOL,
) {
  return await new Promise<number>((resolve, reject) => {
    const socket = new WebSocket(url, protocol, { headers });
    socket.on("error", () => {});
    socket.once("unexpected-response", (_request, response) => {
      response.resume();
      socket.terminate();
      resolve(response.statusCode ?? 0);
    });
    socket.once("open", () => {
      socket.terminate();
      reject(new Error("Unexpected accepted socket."));
    });
  });
}

describe("durable recording routes", () => {
  test("production standalone server handles binary WebSocket recording and finalization", async () => {
    const directory = await mkdtemp(join(tmpdir(), "sotto-recording-standalone-"));
    try {
      const executable = join(directory, "recording-server-probe");
      const built = await Bun.build({
        ...standaloneBuildSettings(
          resolve(import.meta.dirname, "fixtures/recording-server-standalone.ts"),
        ),
        compile: { outfile: executable, autoloadDotenv: false, autoloadBunfig: false },
      });
      expect(built.success).toBe(true);
      const result = Bun.spawnSync([executable]);
      expect(result.stderr.toString()).toBe("");
      expect(result.exitCode).toBe(0);
      expect(result.stdout.toString().trim()).toBe("Compiled recording WebSocket parity passed.");
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }, 15_000);

  test("WebSocket upgrade inherits authentication and origin policy and requires the protocol", async () => {
    const { app, headers, url, snapshot } = await fixture();
    expect(await rejected(url, {})).toBe(401);
    expect(await rejected(url, { ...headers, origin: "https://example.com" })).toBe(403);
    expect(await rejected(url, headers, "other.protocol")).toBe(400);
    expect((await app.inject("/v2/recordings/capabilities")).statusCode).toBe(401);
    expect(
      (await app.inject({ url: "/v2/recordings/capabilities", headers })).json<{
        protocol: string;
        maximumPCMBytes: number;
      }>(),
    ).toEqual({
      protocol: RECORDING_WS_PROTOCOL,
      maximumPCMBytes: 1_048_576,
    });
    expect((await app.inject({ url: "/v2/recordings/not-a-uuid", headers })).statusCode).toBe(400);
    expect((await app.inject({ url: "/v2/recordings?limit=1x", headers })).statusCode).toBe(400);
    const discarded = await app.inject({
      method: "POST",
      url: `/v2/recordings/${snapshot.id}/discard`,
      headers,
    });
    expect(discarded.statusCode).toBe(200);
    expect(discarded.json().captureState).toBe("discarded");
  });

  test("resume accepts snapshots larger than the HTTP request limit after adding session metadata", async () => {
    const { app, headers, url, snapshot } = await fixture();
    const preferences = (
      await app.inject({ url: "/v1/preferences", headers })
    ).json<PreferencesSnapshot>();
    const entries: DictionaryEntry[] = [];
    preferences.preferences.dictionary = { lists: [{ id: "large", name: "Large", entries }] };
    while (Buffer.byteLength(JSON.stringify(preferences)) < 246_000) {
      const index = entries.length;
      entries.push({
        id: `entry-${index}`,
        term: `word-${index}`.padEnd(128, "x"),
        aliases: Array.from({ length: 8 }, (_, alias) =>
          `alias-${index}-${alias}`.padEnd(128, "x"),
        ),
        isPriority: false,
      });
    }
    preferences.preferences.vocabulary = "x".repeat(
      262_140 - Buffer.byteLength(JSON.stringify(preferences)),
    );
    expect(Buffer.byteLength(preferences.preferences.vocabulary)).toBeLessThanOrEqual(16_384);
    expect(
      (await app.inject({ method: "PUT", url: "/v1/preferences", headers, payload: preferences }))
        .statusCode,
    ).toBe(200);
    const created = await app.inject({
      method: "POST",
      url: "/v2/recordings",
      headers,
      payload: {
        requestID: randomUUID(),
        device: { id: "large-settings", name: "Fixture" },
        mode: "test",
      },
    });
    expect(created.statusCode).toBe(201);
    const large = created.json<RecordingSnapshot>();
    expect(
      Buffer.byteLength(JSON.stringify({ type: "snapshot", snapshot: large })),
    ).toBeGreaterThan(262_144);
    const { socket, next } = await connect(url.replace(snapshot.id, large.id), headers);
    socket.send(JSON.stringify({ type: "resume" }));
    expect((await next("snapshot")).snapshot.id).toBe(large.id);
  });

  test("binary audio is durably acknowledged, resumed after lost receipt, finalized and downloadable", async () => {
    const { app, service, headers, snapshot, url } = await fixture();
    const runID = randomUUID().toUpperCase();
    const first = await connect(url, headers);
    first.socket.send(audio(1, runID));
    expect((await first.next("error")).code).toBe("resume_required");
    first.socket.send(JSON.stringify({ type: "resume" }));
    const resumed = await first.next("snapshot");
    const epoch = resumed.snapshot.epoch;
    const continuationID = randomUUID().toUpperCase();
    first.socket.send(JSON.stringify({ type: "context", epoch, continuationID }));
    const contextualized = (await first.next("snapshot")).snapshot;
    expect(contextualized.continuationID).toBe(continuationID);
    first.socket.send(JSON.stringify({ type: "context", epoch, continuationID }));
    expect((await first.next("snapshot")).snapshot.revision).toBe(contextualized.revision);
    first.socket.send(audio(epoch, runID));
    expect(await first.next("ack")).toMatchObject({
      runID,
      kind: "inference",
      nextSequence: 1,
      frameCount: 16_000,
    });
    expect((await first.next("progress")).snapshot.uploadedFrames).toBe(16_000);
    const disconnected = new Promise<void>((resolve) =>
      first.socket.once("close", () => resolve()),
    );
    first.socket.terminate();
    await disconnected;
    const second = await connect(url, headers);
    second.socket.send(JSON.stringify({ type: "resume" }));
    const reconciled = (await second.next("snapshot")).snapshot;
    expect(reconciled.epoch).toBeGreaterThan(epoch);
    expect(reconciled.streams).toMatchObject([{ runID, frameCount: 16_000, nextSequence: 1 }]);
    second.socket.send(audio(reconciled.epoch, runID));
    expect((await second.next("ack")).frameCount).toBe(16_000);
    const changed = Buffer.alloc(16_000 * 4);
    changed.writeFloatLE(0.5, 0);
    second.socket.send(audio(reconciled.epoch, runID, 0, 0, 16_000, changed));
    expect((await second.next("error")).retryable).toBe(false);
    second.socket.send(
      JSON.stringify({
        type: "stop",
        epoch: reconciled.epoch,
        runs: [{ runID, inferenceFrames: 16_000 }],
      }),
    );
    expect((await second.next("snapshot")).snapshot.captureState).toBe("stopped");
    const deadline = Date.now() + 5_000;
    while (
      (await service.get(snapshot.id)).processingState !== "completed" &&
      Date.now() < deadline
    )
      await new Promise((resolve) => setTimeout(resolve, 10));
    const detail = await app.inject({ url: `/v2/recordings/${snapshot.id}`, headers });
    expect(detail.statusCode).toBe(200);
    expect(detail.json().result.finalText).toBe("Hello world.");
    const transcript = await app.inject({
      url: `/v2/recordings/${snapshot.id}/transcript`,
      headers,
    });
    expect(transcript.headers["content-type"]).toContain("text/plain");
    expect(transcript.body).toBe("Hello world.");
    const artifact = await app.inject({
      url: `/v2/recordings/${snapshot.id}/audio/inference`,
      headers,
    });
    expect(artifact.statusCode).toBe(200);
    expect(artifact.rawPayload.subarray(0, 4).toString()).toBe("RIFF");
    expect(artifact.rawPayload.subarray(44)).toEqual(Buffer.alloc(16_000 * 4));
    const perRun = await app.inject({
      url: `/v2/recordings/${snapshot.id}/audio/inference/${runID}`,
      headers,
    });
    expect(perRun.statusCode).toBe(200);
    expect(perRun.rawPayload).toEqual(artifact.rawPayload);
    expect((await app.inject({ url: "/v2/recordings", headers })).json().items[0].id).toBe(
      snapshot.id,
    );
    expect(
      (
        await app.inject({
          method: "POST",
          url: `/v2/recordings/${snapshot.id}/delivery`,
          headers,
          payload: { status: "tested", reportedAt: "2026-01-01T00:00:00Z" },
        })
      ).statusCode,
    ).toBe(200);
  });

  test("a new resume fences the older connected socket and stale headers are rejected", async () => {
    const { headers, url } = await fixture();
    const first = await connect(url, headers);
    first.socket.send(JSON.stringify({ type: "resume" }));
    const oldEpoch = (await first.next("snapshot")).snapshot.epoch;
    const closed = new Promise<number>((resolve) =>
      first.socket.once("close", (code) => resolve(code)),
    );
    const second = await connect(url, headers);
    second.socket.send(JSON.stringify({ type: "resume" }));
    const epoch = (await second.next("snapshot")).snapshot.epoch;
    expect(epoch).toBeGreaterThan(oldEpoch);
    expect(await closed).toBe(1008);
    second.socket.send(audio(oldEpoch, randomUUID()));
    expect((await second.next("error")).code).toBe("stale_epoch");
  });

  test("closing while resume is pending releases the subsequently created subscription", async () => {
    const { headers, url, service, snapshot } = await fixture();
    const { socket } = await connect(url, headers);
    let unblock: (() => void) | undefined;
    let entered: (() => void) | undefined;
    let released: (() => void) | undefined;
    const blocked = new Promise<void>((resolve) => {
      unblock = resolve;
    });
    const started = new Promise<void>((resolve) => {
      entered = resolve;
    });
    const unsubscribed = new Promise<void>((resolve) => {
      released = resolve;
    });
    const resume = service.resume.bind(service);
    service.resume = async (id) => {
      entered?.();
      await blocked;
      return resume(id);
    };
    const subscribe = service.subscribe.bind(service);
    let active = 0;
    service.subscribe = (id, callback) => {
      active += 1;
      const unsubscribe = subscribe(id, callback);
      return () => {
        active -= 1;
        unsubscribe();
        released?.();
      };
    };
    cleanup.push(async () => {
      unblock?.();
    });
    socket.send(JSON.stringify({ type: "resume" }));
    await started;
    const closed = new Promise<void>((resolve) => socket.once("close", () => resolve()));
    socket.terminate();
    await closed;
    unblock?.();
    await unsubscribed;
    expect(active).toBe(0);
    await resume(snapshot.id);
    expect(active).toBe(0);
  });

  test("large pause and final-stop manifests preserve hundreds of capture runs", async () => {
    const { headers, url, service, snapshot } = await fixture();
    const { socket, next } = await connect(url, headers);
    socket.send(JSON.stringify({ type: "resume" }));
    const epoch = (await next("snapshot")).snapshot.epoch;
    const runs = Array.from({ length: 300 }, (_, index) => ({
      runID: randomUUID().toUpperCase(),
      inferenceFrames: index === 0 ? 16_000 : 0,
    }));
    const runTimings = runs.map((run, index) => ({
      runID: run.runID,
      startedAt: new Date(Date.UTC(2026, 0, 1) + index * 2_000).toISOString(),
      endedAt: new Date(
        Date.UTC(2026, 0, 1) + index * 2_000 + (index === 0 ? 1_000 : 0),
      ).toISOString(),
      gapBeforeMilliseconds: 0,
    }));
    expect(Buffer.byteLength(JSON.stringify(runs))).toBeGreaterThan(MAXIMUM_RECORDING_HEADER_BYTES);
    expect(Buffer.byteLength(JSON.stringify(runTimings))).toBeGreaterThan(
      MAXIMUM_RECORDING_HEADER_BYTES,
    );
    socket.send(audio(epoch, runs[0]!.runID));
    await next("ack");
    const pause = JSON.stringify({ type: "pause", epoch, runs, runTimings });
    expect(Buffer.byteLength(pause)).toBeGreaterThan(MAXIMUM_RECORDING_HEADER_BYTES);
    expect(Buffer.byteLength(pause)).toBeLessThan(MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES);
    socket.send(pause);
    expect((await next("snapshot")).snapshot.closedRuns).toHaveLength(300);
    socket.send(JSON.stringify({ type: "stop", epoch, runs, runTimings }));
    const stopped = (await next("snapshot")).snapshot;
    expect(stopped.stopRuns).toHaveLength(300);
    expect(stopped.runTimings).toHaveLength(300);
    const deadline = Date.now() + 5_000;
    while (
      (await service.get(snapshot.id)).processingState !== "completed" &&
      Date.now() < deadline
    )
      await new Promise((resolve) => setTimeout(resolve, 10));
    const finished = await service.detail(snapshot.id);
    expect(finished.snapshot.processingState).toBe("completed");
    expect(finished.snapshot.transcribedFrames).toBe(16_000);
    expect(finished.result?.finalText).toBe("Hello world.");
  });

  test("closed capture runs survive pause and reconnect, then a new run completes the same recording", async () => {
    const { headers, url, service, snapshot } = await fixture();
    const first = await connect(url, headers);
    first.socket.send(JSON.stringify({ type: "resume" }));
    const epoch = (await first.next("snapshot")).snapshot.epoch;
    const firstRun = randomUUID().toUpperCase();
    first.socket.send(audio(epoch, firstRun));
    await first.next("ack");
    const firstTiming = {
      runID: firstRun,
      startedAt: "2026-01-01T00:00:00Z",
      endedAt: "2026-01-01T00:00:01Z",
    };
    first.socket.send(
      JSON.stringify({
        type: "pause",
        epoch,
        runs: [{ runID: firstRun, inferenceFrames: 16_000 }],
        runTimings: [firstTiming],
        interruption: "Audio device disconnected.",
      }),
    );
    const paused = (await first.next("snapshot")).snapshot;
    expect(paused.captureState).toBe("interrupted");
    expect(paused.closedRuns).toEqual([{ runID: firstRun, inferenceFrames: 16_000 }]);
    expect(paused.runTimings).toEqual([firstTiming]);
    expect((await service.detail(snapshot.id)).result).toBeUndefined();
    const disconnected = new Promise<void>((resolve) =>
      first.socket.once("close", () => resolve()),
    );
    first.socket.terminate();
    await disconnected;
    const second = await connect(url, headers);
    second.socket.send(JSON.stringify({ type: "resume" }));
    const resumed = (await second.next("snapshot")).snapshot;
    expect(resumed.closedRuns).toEqual(paused.closedRuns);
    expect(resumed.runTimings).toEqual(paused.runTimings);
    second.socket.send(audio(resumed.epoch, firstRun, 1, 16_000));
    expect((await second.next("error")).retryable).toBe(false);
    const secondRun = randomUUID().toUpperCase();
    second.socket.send(audio(resumed.epoch, secondRun));
    expect((await second.next("ack")).frameCount).toBe(16_000);
    second.socket.send(
      JSON.stringify({
        type: "stop",
        epoch: resumed.epoch,
        runs: [
          { runID: firstRun, inferenceFrames: 16_000 },
          { runID: secondRun, inferenceFrames: 16_000 },
        ],
        runTimings: [
          firstTiming,
          {
            runID: secondRun,
            startedAt: "2026-01-01T00:00:03Z",
            endedAt: "2026-01-01T00:00:04Z",
            gapBeforeMilliseconds: 2_000,
          },
        ],
      }),
    );
    expect((await second.next("snapshot")).snapshot.captureState).toBe("stopped");
    const deadline = Date.now() + 5_000;
    while (
      (await service.get(snapshot.id)).processingState !== "completed" &&
      Date.now() < deadline
    )
      await new Promise((resolve) => setTimeout(resolve, 10));
    const finished = await service.detail(snapshot.id);
    expect(finished.snapshot.processingState).toBe("completed");
    expect(finished.snapshot.uploadedFrames).toBe(32_000);
    expect(finished.snapshot.transcribedFrames).toBe(32_000);
    expect(finished.result?.finalText.length).toBeGreaterThan(0);
  }, 10_000);

  test("binary messages retain their smaller size bound when controls use a larger budget", async () => {
    const { headers, url, service, snapshot } = await fixture();
    const { socket } = await connect(url, headers);
    const closed = new Promise<number>((resolve) => socket.once("close", (code) => resolve(code)));
    socket.send(Buffer.alloc(MAXIMUM_RECORDING_MESSAGE_BYTES + 1));
    expect(await closed).toBe(1009);
    expect((await service.get(snapshot.id)).uploadedFrames).toBe(0);
  });

  test("socket maxPayload rejects controls larger than the two MiB control budget", async () => {
    const { headers, url, service, snapshot } = await fixture();
    const { socket } = await connect(url, headers);
    const closed = new Promise<number>((resolve) => socket.once("close", (code) => resolve(code)));
    socket.send(" ".repeat(MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES + 1));
    expect(await closed).toBe(1009);
    expect((await service.get(snapshot.id)).uploadedFrames).toBe(0);
    expect((await service.get(snapshot.id)).stopRuns).toBeUndefined();
  });

  test("speech processing and compact progress advance before capture stops", async () => {
    const { headers, url, service, snapshot } = await fixture();
    const { socket, next } = await connect(url, headers);
    socket.send(JSON.stringify({ type: "resume" }));
    const epoch = (await next("snapshot")).snapshot.epoch;
    const runID = randomUUID().toUpperCase();
    const frames = 15 * 16_000;
    for (let sequence = 0; sequence < 3; sequence += 1) {
      socket.send(audio(epoch, runID, sequence, sequence * frames, frames));
      expect((await next("ack")).nextSequence).toBe(sequence + 1);
    }
    const deadline = Date.now() + 5_000;
    while ((await service.get(snapshot.id)).transcribedFrames === 0 && Date.now() < deadline)
      await new Promise((resolve) => setTimeout(resolve, 10));
    expect((await service.get(snapshot.id)).captureState).toBe("recording");
    let progress = (await next("progress")).snapshot;
    while (progress.transcribedFrames === 0 && Date.now() < deadline)
      progress = (await next("progress")).snapshot;
    expect(progress.transcribedFrames).toBeGreaterThan(0);
    expect(progress.transcribedFrames).toBeLessThanOrEqual(3 * frames);
    expect(progress.previewText.length).toBeLessThanOrEqual(512);
    expect("result" in progress).toBe(false);
  });

  test("an overproducing client cannot grow the receive queue while disk is slow", async () => {
    const { headers, url, service } = await fixture();
    const { socket, next } = await connect(url, headers);
    socket.send(JSON.stringify({ type: "resume" }));
    const epoch = (await next("snapshot")).snapshot.epoch;
    let release: (() => void) | undefined;
    const blocked = new Promise<void>((resolve) => {
      release = resolve;
    });
    const original = service.appendAudio.bind(service);
    let appends = 0;
    service.appendAudio = async (...args: Parameters<RecordingService["appendAudio"]>) => {
      appends += 1;
      await blocked;
      return original(...args);
    };
    cleanup.push(async () => {
      release?.();
    });
    const closed = new Promise<number>((resolve) => socket.once("close", (code) => resolve(code)));
    const message = audio(epoch, randomUUID(), 0, 0, 262_144);
    for (let index = 0; index < 5; index += 1) socket.send(message);
    expect((await next("error")).code).toBe("upload_backpressure");
    expect(await closed).toBe(1009);
    expect(appends).toBe(1);
    release?.();
  });
});
