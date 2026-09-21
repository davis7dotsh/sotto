import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  decodeRecordingAudioMessage,
  encodeRecordingAudioMessage,
  MAXIMUM_RECORDING_HEADER_BYTES,
  MAXIMUM_RECORDING_MESSAGE_BYTES,
  MAXIMUM_RECORDING_PCM_BYTES,
  parseRecordingClientMessage,
  validateRecordingAudioHeader,
  type RecordingAudioHeader,
  type RecordingStopRequest,
  type RecordingPauseRequest,
  validateRecordingRunTimings,
} from "../src/recording-contract.ts";

const runID = "d65f28dc-35f7-4f66-a5ee-5f124b2398dc";
const audio = (samples = [0, 0.25, -0.25, 1]) => {
  const pcm = new Uint8Array(samples.length * 4);
  const view = new DataView(pcm.buffer);
  samples.forEach((sample, index) => view.setFloat32(index * 4, sample, true));
  const header: RecordingAudioHeader = {
    type: "audio",
    epoch: 1,
    runID,
    kind: "inference",
    sequence: 8192,
    firstFrame: 4_294_967_296,
    format: { sampleRate: 16000, channels: 1 },
    frameCount: samples.length,
    sha256: createHash("sha256").update(pcm).digest("hex"),
  };
  return { header, pcm };
};
const rawMessage = (header: unknown, pcm = new Uint8Array()) => {
  const json = new TextEncoder().encode(JSON.stringify(header));
  const result = new Uint8Array(4 + json.byteLength + pcm.byteLength);
  new DataView(result.buffer).setUint32(0, json.byteLength, false);
  result.set(json, 4);
  result.set(pcm, 4 + json.byteLength);
  return result;
};

describe("long-recording binary contract", () => {
  test("round-trips little-endian audio and counters beyond legacy ceilings", () => {
    const batch = audio();
    const encoded = encodeRecordingAudioMessage(batch.header, batch.pcm);
    expect(encoded.ok).toBe(true);
    if (!encoded.ok) throw new Error(encoded.error.message);
    const prefix = new DataView(encoded.value.buffer).getUint32(0, false);
    expect(prefix).toBeGreaterThan(0);
    expect(encoded.value.byteLength).toBe(4 + prefix + batch.pcm.byteLength);
    expect(decodeRecordingAudioMessage(encoded.value)).toEqual({ ok: true, value: batch });
    // Byte offsets in ws Buffer slices must not change framing or sample alignment.
    const wrapped = new Uint8Array(encoded.value.byteLength + 7);
    wrapped.set(encoded.value, 3);
    expect(decodeRecordingAudioMessage(wrapped.subarray(3, 3 + encoded.value.byteLength))).toEqual({
      ok: true,
      value: batch,
    });
  });

  test("rejects corrupt payloads and non-finite samples despite valid byte counts", () => {
    const batch = audio();
    const corrupt = batch.pcm.slice();
    corrupt[0] = 1;
    expect(decodeRecordingAudioMessage(rawMessage(batch.header, corrupt)).ok).toBe(false);
    for (const sample of [NaN, Infinity, -Infinity]) {
      const invalid = audio([sample]);
      expect(decodeRecordingAudioMessage(rawMessage(invalid.header, invalid.pcm)).ok).toBe(false);
      expect(encodeRecordingAudioMessage(invalid.header, invalid.pcm).ok).toBe(false);
    }
    expect(
      decodeRecordingAudioMessage(rawMessage(batch.header, batch.pcm.subarray(0, 12))).ok,
    ).toBe(false);
  });

  test("rejects truncated, oversized, and malformed UTF-8 framing before audio validation", () => {
    for (let length = 0; length < 4; length++)
      expect(decodeRecordingAudioMessage(new Uint8Array(length)).ok).toBe(false);
    const prefix = new Uint8Array(4);
    new DataView(prefix.buffer).setUint32(0, MAXIMUM_RECORDING_HEADER_BYTES + 1, false);
    expect(decodeRecordingAudioMessage(prefix).ok).toBe(false);
    expect(
      decodeRecordingAudioMessage(new Uint8Array(MAXIMUM_RECORDING_MESSAGE_BYTES + 1)).ok,
    ).toBe(false);
    expect(decodeRecordingAudioMessage(new Uint8Array([0, 0, 0, 1, 255])).ok).toBe(false);
    expect(decodeRecordingAudioMessage(new Uint8Array([0, 0, 0, 2, 123])).ok).toBe(false);
  });

  test("validates safe counters and independent original formats", () => {
    const { header } = audio();
    for (const field of ["sequence", "firstFrame", "frameCount", "epoch"])
      for (const value of [-1, 0.5, Number.MAX_SAFE_INTEGER + 1, null, "1"])
        expect(validateRecordingAudioHeader({ ...header, [field]: value }).ok).toBe(false);
    expect(
      validateRecordingAudioHeader({ ...header, firstFrame: Number.MAX_SAFE_INTEGER }).ok,
    ).toBe(false);
    expect(
      validateRecordingAudioHeader({ ...header, frameCount: MAXIMUM_RECORDING_PCM_BYTES / 4 + 1 })
        .ok,
    ).toBe(false);
    expect(
      validateRecordingAudioHeader({ ...header, format: { sampleRate: 48000, channels: 2 } }).ok,
    ).toBe(false);
    expect(
      validateRecordingAudioHeader({
        ...header,
        kind: "original",
        format: { sampleRate: 48000, channels: 2 },
      }).ok,
    ).toBe(true);
    expect(
      validateRecordingAudioHeader({
        ...header,
        kind: "original",
        format: { sampleRate: 192001, channels: 8 },
      }).ok,
    ).toBe(false);
  });
});

describe("long-recording control contract", () => {
  test("pause closes an exact run while preserving an explicit capture gap", () => {
    const pause: RecordingPauseRequest = {
      type: "pause",
      epoch: 3,
      runs: [{ runID, inferenceFrames: 960000, originalFrames: 2880000 }],
      runTimings: [
        {
          runID,
          startedAt: "2026-09-21T10:00:00Z",
          endedAt: "2026-09-21T10:01:00Z",
          gapBeforeMilliseconds: 1500,
        },
      ],
      interruption: "Microphone disconnected.",
    };
    expect(parseRecordingClientMessage(JSON.stringify(pause))).toEqual({ ok: true, value: pause });
    const timing = pause.runTimings[0];
    for (const invalid of [
      { ...pause, runs: [] },
      { ...pause, runTimings: [] },
      { ...pause, runTimings: [{ ...timing, endedAt: undefined }] },
      { ...pause, runTimings: [{ ...timing, endedAt: "2026-09-21T09:59:00Z" }] },
      { ...pause, runTimings: [{ ...timing, gapBeforeMilliseconds: -1 }] },
      { ...pause, runTimings: [{ ...timing, gapBeforeMilliseconds: 0.5 }] },
      { ...pause, runTimings: [{ ...timing, startedAt: "Monday" }] },
      { ...pause, runTimings: [{ ...timing, runID: "fe005d88-7083-4fca-b86a-0d00b4d54c8e" }] },
      { ...pause, interruption: null },
    ])
      expect(parseRecordingClientMessage(invalid).ok).toBe(false);
    expect(
      parseRecordingClientMessage({
        ...pause,
        runs: [{ runID, inferenceFrames: 0, originalFrames: 0 }],
      }).ok,
    ).toBe(true);
    expect(
      parseRecordingClientMessage({ ...pause, type: "stop", interruption: undefined }).ok,
    ).toBe(true);
    expect(validateRecordingRunTimings([{ runID, startedAt: "2026-09-21T10:00:00.125Z" }]).ok).toBe(
      true,
    );
    expect(
      validateRecordingRunTimings([{ runID, startedAt: "2026-09-21T10:00:00Z" }], true).ok,
    ).toBe(false);
  });

  test("context carries a fenced predecessor ID before streaming audio", () => {
    const context = { type: "context" as const, epoch: 2, continuationID: runID };
    expect(parseRecordingClientMessage(JSON.stringify(context))).toEqual({
      ok: true,
      value: context,
    });
    for (const invalid of [
      { ...context, epoch: 0 },
      { ...context, continuationID: "not-a-uuid" },
      { ...context, continuationID: null },
      { type: "context", continuationID: runID },
    ])
      expect(parseRecordingClientMessage(invalid).ok).toBe(false);
  });

  test("stop preserves large exact endpoints and rejects ambiguous duplicate runs", () => {
    const stop: RecordingStopRequest = {
      type: "stop",
      epoch: 3,
      runs: [{ runID, inferenceFrames: 4_294_967_296, originalFrames: 12_884_901_888 }],
    };
    expect(parseRecordingClientMessage(JSON.stringify(stop))).toEqual({ ok: true, value: stop });
    expect(
      parseRecordingClientMessage({
        ...stop,
        runs: [stop.runs[0], { ...stop.runs[0], runID: runID.toUpperCase() }],
      }).ok,
    ).toBe(false);
    for (const inferenceFrames of [-1, null, 1.5, Number.MAX_SAFE_INTEGER + 1])
      expect(parseRecordingClientMessage({ ...stop, runs: [{ runID, inferenceFrames }] }).ok).toBe(
        false,
      );
    expect(parseRecordingClientMessage({ ...stop, runs: [{ runID, inferenceFrames: 0 }] }).ok).toBe(
      true,
    );
  });

  test("bad controls never throw, and oversized JSON is rejected", () => {
    for (const input of [
      undefined,
      null,
      true,
      [],
      "{",
      { type: "stop", epoch: 0, runs: [] },
      { type: "other" },
      " ".repeat(MAXIMUM_RECORDING_HEADER_BYTES + 1),
    ])
      expect(parseRecordingClientMessage(input).ok).toBe(false);
    expect(parseRecordingClientMessage('{"type":"resume"}')).toEqual({
      ok: true,
      value: { type: "resume" },
    });
    expect(parseRecordingClientMessage('{"type":"ping"}')).toEqual({
      ok: true,
      value: { type: "ping" },
    });
  });
});
