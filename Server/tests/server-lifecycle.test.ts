import { expect, test } from "bun:test";
import { createHash, randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { startServer } from "../src/main.ts";
import { createInferenceConfiguration } from "../src/inference/native-inference.ts";
import { FakeInference } from "./support.ts";

test("shutdown drains legacy inference while a recording is queued behind it", async () => {
  const directory = await mkdtemp(join(tmpdir(), "sotto-shutdown-"));
  let started = 0;
  class BlockedInference extends FakeInference {
    override async transcribe(
      path: string,
      language: string,
      terms: string[],
      progress?: (value: number) => void,
      signal?: AbortSignal,
    ) {
      started++;
      await new Promise<void>((_resolve, reject) => {
        if (signal?.aborted) reject(signal.reason);
        else signal?.addEventListener("abort", () => reject(signal.reason), { once: true });
      });
      return super.transcribe(path, language, terms, progress);
    }
  }
  const server = await startServer(
    {
      host: "127.0.0.1",
      port: 0,
      dataDirectory: directory,
      development: true,
      inference: createInferenceConfiguration({
        speechHelper: "/unused/speech-helper",
        speechModel: "/unused/speech-model",
        vadModel: "/unused/vad-model",
        proofHelper: "/unused/proof-helper",
        proofModel: "/unused/proof-model",
      }),
    },
    new BlockedInference(),
  );
  try {
    const preferences = await server.service.getPreferences();
    preferences.preferences.keepOriginalAudio = false;
    await server.service.updatePreferences(preferences);
    const request = () => ({
      requestID: randomUUID(),
      device: { id: "shutdown", name: "Test Mac" },
      mode: "test" as const,
    });
    const admitted = await server.recordings.create(request());
    const recording = await server.recordings.resume(admitted.id);
    const legacy = await server.service.create(request());
    const format = { sampleRate: 16000, channels: 1 };
    await server.service.appendAudio(legacy.id, "inference", 0, format, Buffer.alloc(64000));
    await server.service.finish(legacy.id, { inferenceFrames: 16000 });
    const pcm = Buffer.alloc(45 * 16000 * 4);
    for (let offset = 0, sequence = 0; offset < pcm.length; sequence++) {
      const bytes = pcm.subarray(offset, Math.min(offset + 512000, pcm.length));
      await server.recordings.appendAudio(
        recording.id,
        {
          type: "audio",
          epoch: recording.epoch,
          runID: recording.requestID,
          kind: "inference",
          sequence,
          firstFrame: offset / 4,
          frameCount: bytes.length / 4,
          format,
          sha256: createHash("sha256").update(bytes).digest("hex"),
        },
        bytes,
      );
      offset += bytes.length;
    }
    const deadline = Date.now() + 3000;
    while (
      (await server.recordings.get(recording.id)).processingState !== "processing" &&
      Date.now() < deadline
    )
      await delay(5);
    expect((await server.recordings.get(recording.id)).processingState).toBe("processing");
    expect(started).toBe(1);
    await server.close();
    expect(started).toBe(1);
  } finally {
    await server.close();
    await rm(directory, { recursive: true, force: true });
  }
}, 10000);
