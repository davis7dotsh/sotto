import { afterEach, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile, mkdir, open } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { RecordingService } from "../src/recording-service.ts";
import { defaultPreferences } from "../src/generation-service.ts";
import { sha256 } from "../src/storage.ts";
import { FakeInference } from "./support.ts";
import {
  MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES,
  type RecordingAudioHeader,
  type RecordingSnapshot,
} from "../src/recording-contract.ts";

class CountingInference extends FakeInference {
  windows: number[] = [];
  fail = false;
  failProof = false;
  text = "Every window stays in order.";
  override async transcribe(path: string) {
    if (this.fail) throw new Error("Speech unavailable; preserve audio.");
    const wav = await readFile(path);
    const frames = wav.readUInt32LE(40) / 4;
    this.windows.push(frames);
    return {
      text: this.text,
      audioSeconds: frames / 16000,
      processingSeconds: 0.01,
      language: "en",
      engineVersion: "fixture",
    };
  }
  override async correct(text: string) {
    if (this.failProof) throw new Error("Proof unavailable.");
    return super.correct(text);
  }
}
const resources: { service: RecordingService; path: string }[] = [];
afterEach(async () => {
  for (const resource of resources.splice(0)) {
    await resource.service.shutdown();
    await rm(resource.path, { recursive: true, force: true });
  }
});
const request = () => ({
  requestID: randomUUID(),
  device: { id: "test-device", name: "Test Mac" },
  mode: "test" as const,
});
async function setup(inference = new CountingInference(), correction = false) {
  const path = await mkdtemp(join(tmpdir(), "sotto-session-test-"));
  const preferences = defaultPreferences();
  preferences.preferences.keepOriginalAudio = false;
  preferences.preferences.textCorrectionEnabled = correction;
  const hooks = { getPreferences: async () => structuredClone(preferences) };
  const service = await RecordingService.open(
    { dataDirectory: path, development: true },
    inference,
    hooks,
  );
  resources.push({ service, path });
  return { service, path, inference, hooks };
}
function header(
  snapshot: RecordingSnapshot,
  runID: string,
  sequence: number,
  firstFrame: number,
  pcm: Buffer,
): RecordingAudioHeader {
  return {
    type: "audio",
    epoch: snapshot.epoch,
    runID,
    kind: "inference",
    sequence,
    firstFrame,
    frameCount: pcm.length / 4,
    format: { sampleRate: 16000, channels: 1 },
    sha256: sha256(pcm),
  };
}
async function waitFor(
  service: RecordingService,
  id: string,
  condition: (value: RecordingSnapshot) => boolean,
) {
  for (let count = 0; count < 1000; count++) {
    const snapshot = await service.get(id);
    if (condition(snapshot)) return snapshot;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("Recording did not reach expected state.");
}
async function restart(context: Awaited<ReturnType<typeof setup>>) {
  await context.service.shutdown();
  const service = await RecordingService.open(
    { dataDirectory: context.path, development: true },
    context.inference,
    context.hooks,
  );
  const resource = resources.find((value) => value.path === context.path)!;
  resource.service = service;
  context.service = service;
  return service;
}

test("durable ACK survives restart and lost acknowledgments replay without duplication", async () => {
  const context = await setup();
  const recording = await context.service.create(request());
  const snapshot = await context.service.resume(recording.id);
  const runID = randomUUID();
  const bytes = Buffer.alloc(64000);
  const sent = header(snapshot, runID, 0, 0, bytes);
  const ack = await context.service.appendAudio(snapshot.id, sent, bytes);
  expect(ack.frameCount).toBe(16000);
  expect(await context.service.appendAudio(snapshot.id, sent, bytes)).toEqual(ack);
  const service = await restart(context);
  const resumed = await service.resume(snapshot.id);
  expect(resumed.streams[0]?.frameCount).toBe(16000);
  expect(resumed.epoch).toBeGreaterThan(snapshot.epoch);
  expect(
    (await service.appendAudio(snapshot.id, { ...sent, epoch: resumed.epoch }, bytes)).frameCount,
  ).toBe(16000);
  await expect(service.appendAudio(snapshot.id, sent, bytes)).rejects.toMatchObject({
    code: "stale_epoch",
  });
  const different = Buffer.alloc(64000);
  different.writeFloatLE(1, 0);
  await expect(
    service.appendAudio(
      snapshot.id,
      { ...sent, epoch: resumed.epoch, sha256: sha256(different) },
      different,
    ),
  ).rejects.toMatchObject({ code: "conflicting_audio" });
});

test("recovery reconciles durable receipt after crash before manifest update", async () => {
  const context = await setup();
  const snapshot = await context.service.resume((await context.service.create(request())).id);
  const runID = randomUUID();
  const bytes = Buffer.alloc(64000);
  await context.service.appendAudio(snapshot.id, header(snapshot, runID, 0, 0, bytes), bytes);
  await context.service.shutdown();
  const path = join(context.path, "sessions", snapshot.id, "manifest.json");
  const manifest = JSON.parse(await readFile(path, "utf8"));
  manifest.snapshot.streams[0].nextSequence = 0;
  manifest.snapshot.streams[0].frameCount = 0;
  manifest.snapshot.uploadedFrames = 0;
  await writeFile(path, JSON.stringify(manifest));
  const service = await restart(context);
  const resumed = await service.resume(snapshot.id);
  expect(resumed.uploadedFrames).toBe(16000);
  expect(resumed.streams[0]?.nextSequence).toBe(1);
});

test("accepted stop totals are immutable and finalization waits for contiguous uploads", async () => {
  const { service } = await setup();
  const snapshot = await service.resume((await service.create(request())).id);
  const runID = randomUUID();
  const bytes = Buffer.alloc(64000);
  await service.appendAudio(snapshot.id, header(snapshot, runID, 0, 0, bytes), bytes);
  const runs = [{ runID, inferenceFrames: 32000 }];
  await service.stop(snapshot.id, snapshot.epoch, runs);
  await service.stop(snapshot.id, snapshot.epoch, runs);
  await expect(
    service.stop(snapshot.id, snapshot.epoch, [{ runID, inferenceFrames: 16000 }]),
  ).rejects.toMatchObject({ code: "stop_conflict" });
  expect((await service.get(snapshot.id)).processingState).not.toBe("completed");
  await expect(
    service.appendAudio(snapshot.id, header(snapshot, runID, 2, 32000, bytes), bytes),
  ).rejects.toMatchObject({ code: "audio_past_stop" });
  await service.appendAudio(snapshot.id, header(snapshot, runID, 1, 16000, bytes), bytes);
  await waitFor(service, snapshot.id, (value) => value.processingState === "completed");
  expect(await service.transcript(snapshot.id)).toContain("Every window stays in order.");
  const result = (await service.detail(snapshot.id)).result;
  expect(result?.status).toBe("completed");
  const file = await service.artifact(snapshot.id, "inference");
  try {
    const exported = Buffer.alloc(44);
    await file.read(exported, 0, 44, 0);
    expect(exported.readUInt32LE(40)).toBe(128000);
  } finally {
    await file.close();
  }
});

test("speech runs during capture and remains bounded; failures preserve retriable audio", async () => {
  const { service, inference } = await setup();
  const snapshot = await service.resume((await service.create(request())).id);
  const runID = randomUUID();
  const bytes = Buffer.alloc(16000 * 15 * 4);
  inference.fail = true;
  for (let sequence = 0; sequence < 3; sequence++)
    await service.appendAudio(
      snapshot.id,
      header(snapshot, runID, sequence, sequence * 240000, bytes),
      bytes,
    );
  const failed = await waitFor(service, snapshot.id, (value) => value.processingState === "failed");
  expect(failed.captureState).toBe("recording");
  expect(failed.uploadedFrames).toBe(720000);
  await service.appendAudio(snapshot.id, header(snapshot, runID, 3, 720000, bytes), bytes);
  inference.fail = false;
  const resumed = await service.resume(snapshot.id);
  const processed = await waitFor(service, snapshot.id, (value) => value.transcribedFrames > 0);
  expect(processed.captureState).toBe("recording");
  await service.stop(snapshot.id, resumed.epoch, [{ runID, inferenceFrames: 960000 }]);
  const complete = await waitFor(
    service,
    snapshot.id,
    (value) => value.processingState === "completed",
  );
  expect(complete.transcribedFrames).toBe(960000);
  expect(Math.max(...inference.windows)).toBeLessThanOrEqual(720000);
});

test("proofreading failure keeps deterministic text and delivery receipts are idempotent", async () => {
  const { service, inference } = await setup(new CountingInference(), true);
  inference.failProof = true;
  const snapshot = await service.resume((await service.create(request())).id);
  const runID = randomUUID();
  const bytes = Buffer.alloc(64000);
  await service.appendAudio(snapshot.id, header(snapshot, runID, 0, 0, bytes), bytes);
  await service.stop(snapshot.id, snapshot.epoch, [{ runID, inferenceFrames: 16000 }]);
  await waitFor(service, snapshot.id, (value) => value.processingState === "completed");
  expect(await service.transcript(snapshot.id)).toBe("Every window stays in order.");
  const delivered = await service.recordDelivery(snapshot.id, {
    status: "inserted",
    reportedAt: new Date().toISOString(),
  });
  expect(
    (
      await service.recordDelivery(snapshot.id, {
        status: "inserted",
        reportedAt: new Date().toISOString(),
      })
    ).delivery,
  ).toEqual(delivered.delivery);
  await expect(
    service.recordDelivery(snapshot.id, { status: "copied", reportedAt: new Date().toISOString() }),
  ).rejects.toMatchObject({
    code: "delivery_recorded",
  });
});

for (const minutes of [30, 60, 120])
  test(`sparse ${minutes}-minute durable fixture preserves exact coverage with bounded inference windows`, async () => {
    const context = await setup();
    const snapshot = await context.service.resume((await context.service.create(request())).id);
    await context.service.shutdown();
    const runID = randomUUID();
    const directory = join(context.path, "sessions", snapshot.id, runID, "inference");
    await mkdir(directory, { recursive: true });
    const chunkFrames = 16000 * 15;
    const bytes = Buffer.alloc(chunkFrames * 4);
    const checksum = sha256(bytes);
    const chunkCount = minutes * 4;
    // Sparse files represent real PCM without allocating a whole-session fixture.
    for (let sequence = 0; sequence < chunkCount; sequence++) {
      const pcm = await open(join(directory, `${sequence}.pcm`), "w", 0o600);
      await pcm.truncate(bytes.length);
      await pcm.close();
      await writeFile(
        join(directory, `${sequence}.json`),
        JSON.stringify({
          runID,
          kind: "inference",
          sequence,
          firstFrame: sequence * chunkFrames,
          frameCount: chunkFrames,
          format: { sampleRate: 16000, channels: 1 },
          sha256: checksum,
        }),
      );
    }
    const path = join(context.path, "sessions", snapshot.id, "manifest.json");
    const manifest = JSON.parse(await readFile(path, "utf8"));
    manifest.snapshot.streams = [
      {
        runID,
        kind: "inference",
        format: { sampleRate: 16000, channels: 1 },
        nextSequence: chunkCount,
        frameCount: chunkFrames * chunkCount,
      },
    ];
    manifest.snapshot.stopRuns = [{ runID, inferenceFrames: chunkFrames * chunkCount }];
    manifest.snapshot.captureState = "stopped";
    manifest.cursors = [{ runID, frameCount: 0, transcribedFrames: 0, proofreadFrames: 0 }];
    await writeFile(path, JSON.stringify(manifest));
    const service = await restart(context);
    const complete = await waitFor(
      service,
      snapshot.id,
      (value) => value.processingState === "completed",
    );
    expect(complete.uploadedFrames).toBe(minutes * 60 * 16000);
    expect(complete.transcribedFrames).toBe(complete.uploadedFrames);
    expect(complete.proofreadFrames).toBe(complete.uploadedFrames);
    expect(context.inference.windows.length).toBeGreaterThanOrEqual((minutes * 60) / 45);
    expect(Math.max(...context.inference.windows)).toBeLessThanOrEqual(45 * 16000);
    expect(
      (await service.transcript(snapshot.id)).match(/Every window stays in order\./gu)?.length,
    ).toBe(context.inference.windows.length);
  }, 30000);

class TimedInference extends CountingInference {
  readonly timedSpeechSpans = true;
  override async transcribe(path: string) {
    const wav = await readFile(path);
    const frames = wav.readUInt32LE(40) / 4;
    this.windows.push(frames);
    const firstSecond = wav.readFloatLE(44);
    const spans = Array.from({ length: Math.ceil(frames / 8000) }, (_, index) => ({
      text: ` word${Math.round(firstSecond * 2) + index}`,
      startSeconds: index / 2,
      endSeconds: Math.min(frames / 16000, (index + 1) / 2),
    }));
    return {
      text: spans
        .map((span) => span.text)
        .join("")
        .trim(),
      spans,
      audioSeconds: frames / 16000,
      processingSeconds: 0.01,
      language: "en",
      engineVersion: "fixture",
    };
  }
}
function rampPCM(firstSecond: number, seconds = 15) {
  const bytes = Buffer.alloc(seconds * 16000 * 4);
  for (let index = 0; index < seconds * 16000; index++)
    bytes.writeFloatLE(firstSecond + index / 16000, index * 4);
  return bytes;
}
test("timed forced windows preserve an overlap checkpoint across restart and insert every word once", async () => {
  const inference = new TimedInference();
  const context = await setup(inference);
  let snapshot = await context.service.resume((await context.service.create(request())).id);
  const runID = randomUUID();
  for (let sequence = 0; sequence < 3; sequence++) {
    const bytes = rampPCM(sequence * 15);
    await context.service.appendAudio(
      snapshot.id,
      header(snapshot, runID, sequence, sequence * 240000, bytes),
      bytes,
    );
  }
  await waitFor(context.service, snapshot.id, (value) => value.transcribedFrames === 45 * 16000);
  const checkpointPath = join(context.path, "sessions", snapshot.id, "manifest.json");
  const checkpoint = JSON.parse(await readFile(checkpointPath, "utf8"));
  expect(checkpoint.cursors[0].pending.spans.length).toBeLessThanOrEqual(20);
  const service = await restart(context);
  snapshot = await service.resume(snapshot.id);
  for (let sequence = 3; sequence < 6; sequence++) {
    const bytes = rampPCM(sequence * 15);
    await service.appendAudio(
      snapshot.id,
      header(snapshot, runID, sequence, sequence * 240000, bytes),
      bytes,
    );
  }
  await service.stop(snapshot.id, snapshot.epoch, [{ runID, inferenceFrames: 90 * 16000 }]);
  const complete = await waitFor(service, snapshot.id, (value) =>
    ["completed", "failed"].includes(value.processingState),
  );
  expect(complete.error).toBeUndefined();
  expect(complete.processingState).toBe("completed");
  const transcript = await service.transcript(snapshot.id);
  expect(Array.from(transcript.match(/word\d+/gu) ?? [])).toEqual(
    Array.from({ length: 180 }, (_, index) => `word${index}`),
  );
});

test("an unadmitted orphan directory cannot prevent startup", async () => {
  const context = await setup();
  const orphanID = randomUUID().toUpperCase();
  await mkdir(join(context.path, "sessions", orphanID, "windows"), { recursive: true });
  const service = await restart(context);
  expect((await service.create(request())).id).not.toBe(orphanID);
});

test("source retention requires matching endpoints and original runs export separately", async () => {
  const context = await setup();
  const preferences = await context.hooks.getPreferences();
  preferences.preferences.keepOriginalAudio = true;
  await context.service.shutdown();
  const service = await RecordingService.open(
    { dataDirectory: context.path, development: true },
    context.inference,
    { getPreferences: async () => preferences },
  );
  context.service = service;
  resources.find((value) => value.path === context.path)!.service = service;
  const snapshot = await service.resume((await service.create(request())).id);
  const firstRun = randomUUID(),
    secondRun = randomUUID();
  for (const [index, runID] of [firstRun, secondRun].entries()) {
    const bytes = Buffer.alloc(64000);
    await service.appendAudio(snapshot.id, header(snapshot, runID, 0, 0, bytes), bytes);
    const sampleRate = index === 0 ? 48000 : 32000;
    const source = Buffer.alloc(sampleRate * 4);
    await service.appendAudio(
      snapshot.id,
      {
        ...header(snapshot, runID, 0, 0, source),
        kind: "original",
        format: { sampleRate, channels: 1 },
      },
      source,
    );
  }
  await expect(
    service.stop(snapshot.id, snapshot.epoch, [
      { runID: firstRun, inferenceFrames: 16000 },
      { runID: secondRun, inferenceFrames: 16000 },
    ]),
  ).rejects.toMatchObject({ code: "invalid_stop" });
  await expect(
    service.stop(snapshot.id, snapshot.epoch, [
      { runID: firstRun, inferenceFrames: 16000, originalFrames: 96000 },
      { runID: secondRun, inferenceFrames: 16000, originalFrames: 32000 },
    ]),
  ).rejects.toMatchObject({ code: "invalid_stop" });
  await service.stop(snapshot.id, snapshot.epoch, [
    { runID: firstRun, inferenceFrames: 16000, originalFrames: 48000 },
    { runID: secondRun, inferenceFrames: 16000, originalFrames: 32000 },
  ]);
  await waitFor(service, snapshot.id, (value) => value.processingState === "completed");
  await expect(service.artifact(snapshot.id, "original")).rejects.toMatchObject({
    code: "mixed_audio_formats",
  });
  const exported = await service.artifact(snapshot.id, "original", firstRun);
  try {
    const header = Buffer.alloc(44);
    await exported.read(header, 0, 44, 0);
    expect(header.readUInt32LE(24)).toBe(48000);
    expect(header.readUInt32LE(40)).toBe(48000 * 4);
  } finally {
    await exported.close();
  }
});

test("explicit discard deletes audio while keeping a restart-safe fenced tombstone", async () => {
  const context = await setup();
  const snapshot = await context.service.resume((await context.service.create(request())).id);
  const runID = randomUUID();
  const bytes = Buffer.alloc(64000);
  await context.service.appendAudio(snapshot.id, header(snapshot, runID, 0, 0, bytes), bytes);
  const discarded = await context.service.discard(snapshot.id);
  expect(discarded.captureState).toBe("discarded");
  expect(discarded.streams).toHaveLength(0);
  await expect(
    readFile(
      join(context.path, "sessions", snapshot.id, runID.toUpperCase(), "inference", "0.pcm"),
    ),
  ).rejects.toMatchObject({ code: "ENOENT" });
  const service = await restart(context);
  expect((await service.get(snapshot.id)).captureState).toBe("discarded");
  await expect(service.resume(snapshot.id)).rejects.toMatchObject({ code: "recording_discarded" });
  expect((await service.history(100)).items).toHaveLength(0);
});

test("continuation is fixed before audio and final composition carries delivered list state", async () => {
  const { service, inference } = await setup();
  const bytes = Buffer.alloc(64000);
  inference.text = "Start a list. One, apples. Two, bananas.";
  const first = await service.resume((await service.create(request())).id);
  const firstRun = randomUUID();
  await service.appendAudio(first.id, header(first, firstRun, 0, 0, bytes), bytes);
  await service.stop(first.id, first.epoch, [{ runID: firstRun, inferenceFrames: 16000 }]);
  await waitFor(service, first.id, (value) => value.processingState === "completed");
  await service.recordDelivery(first.id, {
    status: "inserted",
    reportedAt: new Date().toISOString(),
  });
  expect((await service.detail(first.id)).result?.continuation?.list?.nextNumber).toBe(3);
  const second = await service.resume((await service.create(request())).id);
  const anchored = await service.setContext(second.id, second.epoch, first.id);
  expect(anchored.continuationID).toBe(first.id);
  await service.setContext(second.id, second.epoch, first.id.toLowerCase());
  await expect(service.setContext(second.id, second.epoch, randomUUID())).rejects.toMatchObject({
    code: "context_conflict",
  });
  inference.text = "Next item, oranges.";
  const secondRun = randomUUID();
  await service.appendAudio(second.id, header(second, secondRun, 0, 0, bytes), bytes);
  await service.stop(second.id, second.epoch, [{ runID: secondRun, inferenceFrames: 16000 }]);
  await waitFor(service, second.id, (value) => value.processingState === "completed");
  const result = (await service.detail(second.id)).result;
  expect(result?.insertionText).toBe("\n3. oranges");
  expect(result?.previewText).toBe("1. apples\n2. bananas\n3. oranges");
  expect(result?.continuation?.list?.nextNumber).toBe(4);
  const third = await service.resume((await service.create(request())).id);
  const thirdRun = randomUUID();
  await service.appendAudio(third.id, header(third, thirdRun, 0, 0, bytes), bytes);
  await expect(service.setContext(third.id, third.epoch, first.id)).rejects.toMatchObject({
    code: "context_too_late",
  });
});

test("durable pause flushes its tail, records the gap and resumes one session without early completion", async () => {
  const context = await setup();
  const bytes = Buffer.alloc(64000);
  let snapshot = await context.service.resume((await context.service.create(request())).id);
  const firstRun = randomUUID(),
    nextRun = randomUUID();
  const timing = {
    runID: firstRun,
    startedAt: "2026-09-21T10:00:00.000Z",
    endedAt: "2026-09-21T10:00:02.000Z",
    gapBeforeMilliseconds: 0,
  };
  await context.service.appendAudio(snapshot.id, header(snapshot, firstRun, 0, 0, bytes), bytes);
  const closed = [{ runID: firstRun, inferenceFrames: 32000 }];
  const paused = await context.service.pause(
    snapshot.id,
    snapshot.epoch,
    closed,
    [timing],
    "Microphone disconnected.",
  );
  expect(paused.captureState).toBe("interrupted");
  expect(paused.closedRuns?.[0]?.inferenceFrames).toBe(32000);
  // The pause is durable even while a lost network batch is still pending.
  await context.service.appendAudio(
    snapshot.id,
    header(snapshot, firstRun, 1, 16000, bytes),
    bytes,
  );
  const flushed = await waitFor(
    context.service,
    snapshot.id,
    (value) => value.transcribedFrames === 32000,
  );
  expect(flushed.captureState).toBe("interrupted");
  expect(flushed.processingState).not.toBe("completed");
  await expect(
    context.service.appendAudio(snapshot.id, header(snapshot, firstRun, 2, 32000, bytes), bytes),
  ).rejects.toMatchObject({ code: "audio_past_stop" });
  const service = await restart(context);
  snapshot = await service.resume(snapshot.id);
  await expect(
    service.pause(
      snapshot.id,
      snapshot.epoch,
      [{ runID: firstRun, inferenceFrames: 48000 }],
      [timing],
    ),
  ).rejects.toMatchObject({ code: "pause_conflict" });
  await service.appendAudio(snapshot.id, header(snapshot, nextRun, 0, 0, bytes), bytes);
  const replay = await service.pause(snapshot.id, snapshot.epoch, closed, [timing]);
  expect(replay.captureState).toBe("recording");
  const nextTiming = {
    runID: nextRun,
    startedAt: "2026-09-21T10:05:00.000Z",
    endedAt: "2026-09-21T10:05:01.000Z",
    gapBeforeMilliseconds: 298000,
  };
  await expect(
    service.stop(
      snapshot.id,
      snapshot.epoch,
      [{ runID: nextRun, inferenceFrames: 16000 }],
      [nextTiming],
    ),
  ).rejects.toMatchObject({ code: "stop_conflict" });
  await service.stop(
    snapshot.id,
    snapshot.epoch,
    [...closed, { runID: nextRun, inferenceFrames: 16000 }],
    [timing, nextTiming],
  );
  const complete = await waitFor(
    service,
    snapshot.id,
    (value) => value.processingState === "completed",
  );
  expect(complete.transcribedFrames).toBe(48000);
  expect(complete.runTimings?.[1]?.gapBeforeMilliseconds).toBe(298000);
  expect(
    (await service.transcript(snapshot.id)).match(/Every window stays in order\./gu)?.length,
  ).toBe(2);
});

class OrderedInference extends CountingInference {
  override async transcribe(path: string) {
    const wav = await readFile(path);
    const frames = wav.readUInt32LE(40) / 4;
    this.windows.push(frames);
    return {
      text: wav.readFloatLE(44) < 0.15 ? "Alpha." : "Beta.",
      audioSeconds: frames / 16000,
      processingSeconds: 0.01,
      language: "en",
      engineVersion: "fixture",
    };
  }
}
function constantPCM(value: number) {
  const bytes = Buffer.alloc(15 * 16000 * 4);
  for (let index = 0; index < bytes.length; index += 4) bytes.writeFloatLE(value, index);
  return bytes;
}
test("a later run cannot leapfrog an earlier closed run with no currently queued frames", async () => {
  const inference = new OrderedInference();
  const { service } = await setup(inference);
  const snapshot = await service.resume((await service.create(request())).id);
  const firstRun = randomUUID(),
    nextRun = randomUUID();
  const alpha = constantPCM(0.1),
    beta = constantPCM(0.2);
  for (let sequence = 0; sequence < 3; sequence++)
    await service.appendAudio(
      snapshot.id,
      header(snapshot, firstRun, sequence, sequence * 240000, alpha),
      alpha,
    );
  await waitFor(service, snapshot.id, (value) => value.transcribedFrames === 45 * 16000);
  const firstTiming = {
    runID: firstRun,
    startedAt: "2026-09-21T10:00:00Z",
    endedAt: "2026-09-21T10:01:00Z",
  };
  await service.pause(
    snapshot.id,
    snapshot.epoch,
    [{ runID: firstRun, inferenceFrames: 60 * 16000 }],
    [firstTiming],
  );
  for (let sequence = 0; sequence < 3; sequence++)
    await service.appendAudio(
      snapshot.id,
      header(snapshot, nextRun, sequence, sequence * 240000, beta),
      beta,
    );
  await new Promise((resolve) => setTimeout(resolve, 25));
  expect(inference.windows).toEqual([45 * 16000]);
  expect((await service.get(snapshot.id)).transcribedFrames).toBe(45 * 16000);
  await service.appendAudio(snapshot.id, header(snapshot, firstRun, 3, 45 * 16000, alpha), alpha);
  await service.stop(
    snapshot.id,
    snapshot.epoch,
    [
      { runID: firstRun, inferenceFrames: 60 * 16000 },
      { runID: nextRun, inferenceFrames: 45 * 16000 },
    ],
    [
      firstTiming,
      {
        runID: nextRun,
        startedAt: "2026-09-21T10:05:00Z",
        endedAt: "2026-09-21T10:05:45Z",
        gapBeforeMilliseconds: 240000,
      },
    ],
  );
  await waitFor(service, snapshot.id, (value) => value.processingState === "completed");
  expect(await service.transcript(snapshot.id)).toBe("Alpha. Alpha. Beta.");
  expect(inference.windows).toEqual([45 * 16000, 15 * 16000, 45 * 16000]);
});

class BoundaryInference extends CountingInference {
  boundaries: number[] = [];
  async findSpeechBoundary(path: string) {
    const wav = await readFile(path);
    this.boundaries.push(wav.readUInt32LE(40) / 4);
    return 40;
  }
}
test("native boundary preflight cuts a bounded live window while finalization keeps its exact tail", async () => {
  const inference = new BoundaryInference();
  const { service } = await setup(inference);
  const snapshot = await service.resume((await service.create(request())).id);
  const runID = randomUUID();
  const bytes = constantPCM(0.1);
  for (let sequence = 0; sequence < 4; sequence++)
    await service.appendAudio(
      snapshot.id,
      header(snapshot, runID, sequence, sequence * 240000, bytes),
      bytes,
    );
  await waitFor(service, snapshot.id, (value) => value.transcribedFrames === 40 * 16000);
  await service.stop(snapshot.id, snapshot.epoch, [{ runID, inferenceFrames: 60 * 16000 }]);
  const complete = await waitFor(
    service,
    snapshot.id,
    (value) => value.processingState === "completed",
  );
  expect(complete.transcribedFrames).toBe(60 * 16000);
  expect(inference.boundaries).toEqual([45 * 16000]);
  expect(inference.windows).toEqual([40 * 16000, 20 * 16000]);
});

test("shutdown fences late upload and recording controls before they can mutate durable storage", async () => {
  const { service, path } = await setup();
  const snapshot = await service.resume((await service.create(request())).id);
  const runID = randomUUID();
  const bytes = Buffer.alloc(64000);
  await service.appendAudio(snapshot.id, header(snapshot, runID, 0, 0, bytes), bytes);
  const manifestPath = join(path, "sessions", snapshot.id, "manifest.json");
  const before = await readFile(manifestPath, "utf8");
  await service.shutdown();
  const endpoints = [{ runID, inferenceFrames: 32000 }];
  const timings = [{ runID, startedAt: "2026-09-21T10:00:00Z", endedAt: "2026-09-21T10:00:02Z" }];
  const mutations = [
    service.appendAudio(snapshot.id, header(snapshot, runID, 1, 16000, bytes), bytes),
    service.resume(snapshot.id),
    service.setContext(snapshot.id, snapshot.epoch, randomUUID()),
    service.pause(snapshot.id, snapshot.epoch, endpoints, timings),
    service.stop(snapshot.id, snapshot.epoch, endpoints, timings),
    service.discard(snapshot.id),
    service.recordDelivery(snapshot.id, {
      status: "inserted",
      reportedAt: new Date().toISOString(),
    }),
    service.create(request()),
  ];
  const outcomes = await Promise.allSettled(mutations);
  for (const outcome of outcomes) {
    expect(outcome.status).toBe("rejected");
    if (outcome.status === "rejected")
      expect(outcome.reason).toMatchObject({ code: "server_stopping", status: 503 });
  }
  // Socket-close cleanup may arrive after shutdown; it is a harmless read.
  expect((await service.interrupt(snapshot.id, snapshot.epoch)).captureState).toBe("recording");
  expect(await readFile(manifestPath, "utf8")).toBe(before);
  await expect(
    readFile(join(path, "sessions", snapshot.id, runID.toUpperCase(), "inference", "1.json")),
  ).rejects.toMatchObject({ code: "ENOENT" });
});

test("near-budget pause reserves its final stop snapshot and survives finalization and restart", async () => {
  const { service, path, hooks } = await setup();
  const snapshot = await service.resume((await service.create(request())).id);
  const run = (index: number) => ({
    runID: `${index.toString(16).padStart(8, "0")}-0000-4000-8000-000000000000`.toUpperCase(),
    inferenceFrames: index === 0 ? 16_000 : 0,
  });
  const timing = (index: number) => ({
    runID: run(index).runID,
    startedAt: "2026-09-21T10:00:00.000Z",
    endedAt: index === 0 ? "2026-09-21T10:00:01.000Z" : "2026-09-21T10:00:00.000Z",
    gapBeforeMilliseconds: 0,
  });
  const lifecycleBudget = MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES / 2;
  const overhead = Buffer.byteLength(
    JSON.stringify({ closedRuns: [], stopRuns: [], runTimings: [] }),
  );
  const bytesPerRun =
    2 * (Buffer.byteLength(JSON.stringify(run(1))) + 1) +
    Buffer.byteLength(JSON.stringify(timing(1))) +
    1;
  const count = Math.floor((lifecycleBudget - overhead - 8 + 3) / bytesPerRun) - 1;
  const runs = Array.from({ length: count }, (_, index) => run(index));
  const runTimings = runs.map((_, index) => timing(index));
  runs[count - 1]!.inferenceFrames = 16_000;
  runTimings[count - 1]!.endedAt = "2026-09-21T10:00:01.000Z";
  const size = Buffer.byteLength(JSON.stringify({ closedRuns: runs, stopRuns: runs, runTimings }));
  expect(size).toBeLessThanOrEqual(lifecycleBudget);
  expect(lifecycleBudget - size).toBeLessThan(2 * bytesPerRun);
  const pcm = Buffer.alloc(64_000);
  await service.appendAudio(snapshot.id, header(snapshot, runs[0]!.runID, 0, 0, pcm), pcm);
  await service.pause(snapshot.id, snapshot.epoch, runs.slice(0, -1), runTimings.slice(0, -1));
  // The next active run's endpoint copy and timing were budgeted at its ACK.
  await service.appendAudio(snapshot.id, header(snapshot, runs[count - 1]!.runID, 0, 0, pcm), pcm);
  const paused = await service.pause(snapshot.id, snapshot.epoch, runs, runTimings);
  expect(paused.closedRuns).toHaveLength(count);
  expect(Buffer.byteLength(JSON.stringify({ type: "snapshot", snapshot: paused }))).toBeLessThan(
    MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES,
  );
  const accepted = await readFile(join(path, "sessions", snapshot.id, "manifest.json"), "utf8");
  const extraRuns = [...runs, run(count), run(count + 1)];
  const extraTimings = [...runTimings, timing(count), timing(count + 1)];
  await expect(
    service.pause(snapshot.id, snapshot.epoch, extraRuns, extraTimings),
  ).rejects.toMatchObject({ code: "metadata_too_large", status: 413 });
  await expect(
    service.stop(snapshot.id, snapshot.epoch, extraRuns, extraTimings),
  ).rejects.toMatchObject({ code: "metadata_too_large", status: 413 });
  expect((await service.get(snapshot.id)).closedRuns).toEqual(paused.closedRuns);
  expect((await service.get(snapshot.id)).stopRuns).toBeUndefined();
  // A worker may checkpoint the accepted audio, but rejected control cannot change lifecycle data.
  expect(
    JSON.parse(await readFile(join(path, "sessions", snapshot.id, "manifest.json"), "utf8"))
      .snapshot.closedRuns,
  ).toEqual(JSON.parse(accepted).snapshot.closedRuns);
  await service.shutdown();
  const restarted = await RecordingService.open(
    { dataDirectory: path, development: true },
    new CountingInference(),
    hooks,
  );
  resources[resources.length - 1]!.service = restarted;
  const resumed = await restarted.resume(snapshot.id);
  expect(resumed.closedRuns).toEqual(paused.closedRuns);
  const stopped = await restarted.stop(snapshot.id, resumed.epoch, runs, runTimings);
  expect(Buffer.byteLength(JSON.stringify({ type: "snapshot", snapshot: stopped }))).toBeLessThan(
    MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES,
  );
  const completed = await waitFor(
    restarted,
    snapshot.id,
    (value) => value.processingState === "completed",
  );
  expect(completed.transcribedFrames).toBe(32_000);
  expect(completed.stopRuns).toHaveLength(count);
  await restarted.shutdown();
  const finalized = await RecordingService.open(
    { dataDirectory: path, development: true },
    new CountingInference(),
    hooks,
  );
  resources[resources.length - 1]!.service = finalized;
  const detail = await finalized.detail(snapshot.id);
  expect(detail.snapshot.processingState).toBe("completed");
  expect(detail.snapshot.stopRuns).toHaveLength(count);
  expect(detail.result?.finalText).toBe(
    "Every window stays in order. Every window stays in order.",
  );
}, 15_000);

test("direct pause and stop APIs apply the combined wire control budget before mutation", async () => {
  const { service } = await setup();
  const snapshot = await service.resume((await service.create(request())).id);
  const runs = Array.from({ length: 12_000 }, (_, index) => ({
    runID: `${index.toString(16).padStart(8, "0")}-0000-4000-8000-000000000000`,
    inferenceFrames: 0,
  }));
  const runTimings = runs.map(({ runID }) => ({
    runID,
    startedAt: "2026-09-21T10:00:00Z",
    endedAt: "2026-09-21T10:00:00Z",
  }));
  expect(Buffer.byteLength(JSON.stringify(runs))).toBeLessThan(
    MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES,
  );
  expect(Buffer.byteLength(JSON.stringify(runTimings))).toBeLessThan(
    MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES,
  );
  expect(
    Buffer.byteLength(JSON.stringify({ type: "stop", epoch: snapshot.epoch, runs, runTimings })),
  ).toBeGreaterThan(MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES);
  await expect(service.stop(snapshot.id, snapshot.epoch, runs, runTimings)).rejects.toMatchObject({
    code: "control_too_large",
    status: 413,
  });
  await expect(service.pause(snapshot.id, snapshot.epoch, runs, runTimings)).rejects.toMatchObject({
    code: "control_too_large",
    status: 413,
  });
  expect(await service.get(snapshot.id)).toEqual(snapshot);
});
