import { strict as assert } from "node:assert";
import { createHash, randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInferenceConfiguration } from "../../src/inference/native-inference.ts";
import { startServer } from "../../src/main.ts";
import {
  encodeRecordingAudioMessage,
  RECORDING_WS_PROTOCOL,
  type RecordingServerMessage,
} from "../../src/recording-contract.ts";
import { FakeInference } from "../support.ts";

assert.equal(Bun.isStandaloneExecutable, true);
const directory = await mkdtemp(join(tmpdir(), "sotto-recording-compiled-runtime-"));
const missing = join(directory, "missing");
const server = await startServer(
  {
    host: "127.0.0.1",
    port: 0,
    development: true,
    dataDirectory: join(directory, "data"),
    inference: createInferenceConfiguration({
      speechHelper: missing,
      speechModel: missing,
      vadModel: missing,
      proofHelper: missing,
      proofModel: missing,
    }),
  },
  new FakeInference(),
);
let socket: WebSocket | undefined;
try {
  const preferences = await server.service.getPreferences();
  preferences.preferences.keepOriginalAudio = false;
  await server.service.updatePreferences(preferences);
  const capabilities = await (await fetch(`${server.address}/v2/recordings/capabilities`)).json();
  assert.equal(capabilities.protocol, RECORDING_WS_PROTOCOL);
  const response = await fetch(`${server.address}/v2/recordings`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      requestID: randomUUID(),
      device: { id: "compiled-recording", name: "Fixture" },
      mode: "test",
    }),
  });
  assert.equal(response.status, 201);
  const recording = await response.json();
  socket = new WebSocket(
    `${server.address.replace("http:", "ws:")}/v2/recordings/${recording.id}/stream`,
    RECORDING_WS_PROTOCOL,
  );
  const connected = socket;
  await new Promise<void>((resolve, reject) => {
    connected.addEventListener("open", () => resolve(), { once: true });
    connected.addEventListener(
      "error",
      () => reject(new Error("Compiled WebSocket failed to open.")),
      { once: true },
    );
  });
  const receive = <Type extends RecordingServerMessage["type"]>(type: Type) =>
    new Promise<RecordingServerMessage & { type: Type }>((resolve, reject) => {
      const timeout = setTimeout(() => {
        connected.removeEventListener("message", listener);
        reject(new Error(`Compiled socket timed out waiting for ${type}.`));
      }, 5_000);
      const listener = (event: MessageEvent) => {
        const message: RecordingServerMessage = JSON.parse(String(event.data));
        if (message.type === "error") {
          clearTimeout(timeout);
          connected.removeEventListener("message", listener);
          reject(
            new Error(`Compiled recording protocol error: ${message.code}: ${message.message}`),
          );
          return;
        }
        if (message.type !== type) return;
        clearTimeout(timeout);
        connected.removeEventListener("message", listener);
        resolve(message as RecordingServerMessage & { type: Type });
      };
      connected.addEventListener("message", listener);
    });
  const resumed = receive("snapshot");
  connected.send(JSON.stringify({ type: "resume" }));
  const epoch = (await resumed).snapshot.epoch;
  const runID = randomUUID().toUpperCase();
  const pcm = new Uint8Array(16_000 * 4);
  const encoded = encodeRecordingAudioMessage(
    {
      type: "audio",
      epoch,
      runID,
      kind: "inference",
      sequence: 0,
      firstFrame: 0,
      format: { sampleRate: 16_000, channels: 1 },
      frameCount: 16_000,
      sha256: createHash("sha256").update(pcm).digest("hex"),
    },
    pcm,
  );
  if (!encoded.ok) throw new Error(encoded.error.message);
  const acknowledged = receive("ack");
  connected.send(encoded.value);
  assert.equal((await acknowledged).frameCount, 16_000);
  const stopped = receive("snapshot");
  connected.send(
    JSON.stringify({ type: "stop", epoch, runs: [{ runID, inferenceFrames: 16_000 }] }),
  );
  assert.equal((await stopped).snapshot.captureState, "stopped");
  const deadline = Date.now() + 5_000;
  while (true) {
    const detail = await (await fetch(`${server.address}/v2/recordings/${recording.id}`)).json();
    if (detail.result) {
      assert.equal(detail.result.finalText, "Hello world.");
      break;
    }
    if (Date.now() > deadline) throw new Error("Compiled recording did not finalize.");
    await Bun.sleep(10);
  }
  const closed = new Promise<void>((resolve) =>
    connected.addEventListener("close", () => resolve(), { once: true }),
  );
  connected.close();
  await closed;
  console.log("Compiled recording WebSocket parity passed.");
} finally {
  socket?.close();
  await server.close();
  await rm(directory, { recursive: true, force: true });
}
