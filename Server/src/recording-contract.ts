import { createHash } from "node:crypto";
import type {
  AudioKind,
  AudioStreamFormat,
  CreateGenerationRequest,
  GenerationRecord,
  PreferencesSnapshot,
} from "./api.ts";

export const RECORDING_WS_PROTOCOL = "sotto.recording.v1";
export const MAXIMUM_RECORDING_PCM_BYTES = 1_048_576;
export const MAXIMUM_RECORDING_HEADER_BYTES = 16_384;
export const MAXIMUM_RECORDING_MESSAGE_BYTES =
  4 + MAXIMUM_RECORDING_HEADER_BYTES + MAXIMUM_RECORDING_PCM_BYTES;
export const MAXIMUM_RECORDING_IN_FLIGHT_BYTES = 4 * MAXIMUM_RECORDING_MESSAGE_BYTES;
export const MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES = 2 * 1_048_576;
export const MAXIMUM_RECORDING_SERVER_CONTROL_MESSAGE_BYTES =
  MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES;

export type CreateRecordingRequest = CreateGenerationRequest;
export type RecordingCapabilities = {
  protocol: typeof RECORDING_WS_PROTOCOL;
  maximumPCMBytes: number;
};
export type RecordingCaptureState = "recording" | "interrupted" | "stopped" | "discarded";
export type RecordingProcessingState = "queued" | "processing" | "completed" | "failed";
export type RecordingProtocolError = { code: string; message: string; retryable: boolean };
export type RecordingResult<Value> =
  { ok: true; value: Value } | { ok: false; error: RecordingProtocolError };

export type RecordingStreamCheckpoint = {
  runID: string;
  kind: AudioKind;
  format: AudioStreamFormat;
  nextSequence: number;
  frameCount: number;
};
export type RecordingRunEndpoint = {
  runID: string;
  inferenceFrames: number;
  originalFrames?: number;
};
export type RecordingRunTiming = {
  runID: string;
  startedAt: string;
  endedAt?: string;
  gapBeforeMilliseconds?: number;
};
export type RecordingSnapshot = {
  id: string;
  requestID: string;
  device: CreateGenerationRequest["device"];
  mode: CreateGenerationRequest["mode"];
  settings: PreferencesSnapshot;
  createdAt: string;
  revision: number;
  captureState: RecordingCaptureState;
  processingState: RecordingProcessingState;
  uploadedFrames: number;
  transcribedFrames: number;
  proofreadFrames: number;
  streams: RecordingStreamCheckpoint[];
  epoch: number;
  stopRuns?: RecordingRunEndpoint[];
  closedRuns?: RecordingRunEndpoint[];
  runTimings?: RecordingRunTiming[];
  continuationID?: string;
  error?: string;
  previewText: string;
};
export type RecordingDetail = { snapshot: RecordingSnapshot; result?: GenerationRecord };
export type RecordingPage = { items: RecordingSnapshot[]; nextCursor?: string };
export type RecordingAudioHeader = {
  type: "audio";
  epoch: number;
  runID: string;
  kind: AudioKind;
  sequence: number;
  firstFrame: number;
  format: AudioStreamFormat;
  frameCount: number;
  sha256: string;
};
export type RecordingAudioMessage = { header: RecordingAudioHeader; pcm: Uint8Array };
export type RecordingStopRequest = {
  type: "stop";
  epoch: number;
  runs: RecordingRunEndpoint[];
  runTimings?: RecordingRunTiming[];
};
export type RecordingPauseRequest = {
  type: "pause";
  epoch: number;
  runs: RecordingRunEndpoint[];
  runTimings: RecordingRunTiming[];
  interruption?: string;
};
export type RecordingContextRequest = {
  type: "context";
  epoch: number;
  continuationID: string;
};
export type RecordingClientMessage =
  | { type: "resume" }
  | RecordingStopRequest
  | RecordingPauseRequest
  | RecordingContextRequest
  | { type: "ping" };
export type RecordingAck = {
  type: "ack";
  runID: string;
  kind: AudioKind;
  nextSequence: number;
  frameCount: number;
  revision: number;
};
export type RecordingServerMessage =
  | { type: "snapshot" | "progress"; snapshot: RecordingSnapshot }
  | RecordingAck
  | ({ type: "error" } & RecordingProtocolError);

const invalid = (message: string): RecordingResult<never> => ({
  ok: false,
  error: { code: "invalid_recording_message", message, retryable: false },
});
const object = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const integer = (value: unknown, minimum = 0): value is number =>
  typeof value === "number" && Number.isSafeInteger(value) && value >= minimum;
const uuid = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const sha256 = (value: unknown): value is string =>
  typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const timestamp = (value: unknown): value is string =>
  typeof value === "string" &&
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(value) &&
  Number.isFinite(Date.parse(value));

export function validateRecordingRunTimings(
  value: unknown,
  requireClosed = false,
): RecordingResult<RecordingRunTiming[]> {
  if (!Array.isArray(value)) return invalid("Capture run timings must be an array.");
  const timings: RecordingRunTiming[] = [];
  const identifiers = new Set<string>();
  for (const timing of value) {
    if (
      !object(timing) ||
      !uuid(timing.runID) ||
      !timestamp(timing.startedAt) ||
      (timing.endedAt !== undefined &&
        (!timestamp(timing.endedAt) ||
          Date.parse(timing.endedAt) < Date.parse(timing.startedAt))) ||
      (requireClosed && timing.endedAt === undefined) ||
      (timing.gapBeforeMilliseconds !== undefined && !integer(timing.gapBeforeMilliseconds))
    )
      return invalid(
        "Run timings require valid IDs, ordered ISO8601 timestamps, and nonnegative gaps.",
      );
    const identifier = timing.runID.toLowerCase();
    if (identifiers.has(identifier))
      return invalid("Capture run timing contains duplicate run IDs.");
    identifiers.add(identifier);
    timings.push({
      runID: timing.runID,
      startedAt: timing.startedAt,
      ...(timing.endedAt === undefined ? {} : { endedAt: timing.endedAt }),
      ...(timing.gapBeforeMilliseconds === undefined
        ? {}
        : { gapBeforeMilliseconds: timing.gapBeforeMilliseconds }),
    });
  }
  return { ok: true, value: timings };
}

export function validateRecordingAudioHeader(
  value: unknown,
): RecordingResult<RecordingAudioHeader> {
  if (
    !object(value) ||
    value.type !== "audio" ||
    !integer(value.epoch, 1) ||
    !uuid(value.runID) ||
    (value.kind !== "inference" && value.kind !== "original") ||
    !integer(value.sequence) ||
    !integer(value.firstFrame) ||
    !integer(value.frameCount, 1) ||
    !integer(value.firstFrame + value.frameCount) ||
    !object(value.format) ||
    !integer(value.format.sampleRate, 8_000) ||
    value.format.sampleRate > 192_000 ||
    !integer(value.format.channels, 1) ||
    value.format.channels > 8 ||
    !sha256(value.sha256)
  )
    return invalid("Invalid audio header fields, format, counters, or SHA-256.");
  if (
    value.kind === "inference" &&
    (value.format.sampleRate !== 16_000 || value.format.channels !== 1)
  )
    return invalid("Inference audio must be 16 kHz mono float32 PCM.");
  if (value.frameCount * value.format.channels * 4 > MAXIMUM_RECORDING_PCM_BYTES)
    return invalid("Audio PCM exceeds the one MiB message limit.");
  return {
    ok: true,
    value: {
      type: "audio",
      epoch: value.epoch,
      runID: value.runID,
      kind: value.kind,
      sequence: value.sequence,
      firstFrame: value.firstFrame,
      frameCount: value.frameCount,
      format: { sampleRate: value.format.sampleRate, channels: value.format.channels },
      sha256: value.sha256,
    },
  };
}

export function parseRecordingClientMessage(
  input: unknown,
): RecordingResult<RecordingClientMessage> {
  let value: unknown = input;
  if (typeof input === "string") {
    if (Buffer.byteLength(input) > MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES)
      return invalid("Recording control JSON exceeds the control size limit.");
    try {
      value = JSON.parse(input);
    } catch {
      return invalid("Recording control message is not valid JSON.");
    }
  }
  if (!object(value)) return invalid("Recording control message must be an object.");
  if (typeof input !== "string") {
    try {
      if (Buffer.byteLength(JSON.stringify(value)) > MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES)
        return invalid("Recording control JSON exceeds the control size limit.");
    } catch {
      return invalid("Recording control message is not JSON serializable.");
    }
  }
  if (value.type === "resume" || value.type === "ping")
    return { ok: true, value: { type: value.type } };
  if (value.type === "context") {
    if (!integer(value.epoch, 1) || !uuid(value.continuationID))
      return invalid("Recording context requires a connection epoch and continuation ID.");
    return {
      ok: true,
      value: { type: "context", epoch: value.epoch, continuationID: value.continuationID },
    };
  }
  if (
    (value.type !== "stop" && value.type !== "pause") ||
    !integer(value.epoch, 1) ||
    !Array.isArray(value.runs)
  )
    return invalid(
      "Expected a resume, context, ping, pause, or stop message with a connection epoch.",
    );
  const runs: RecordingRunEndpoint[] = [];
  const identifiers = new Set<string>();
  for (const run of value.runs) {
    if (
      !object(run) ||
      !uuid(run.runID) ||
      !integer(run.inferenceFrames) ||
      (run.originalFrames !== undefined && !integer(run.originalFrames))
    )
      return invalid("Run endpoints require valid run IDs and nonnegative frame totals.");
    const key = run.runID.toLowerCase();
    if (identifiers.has(key)) return invalid("Control contains duplicate capture runs.");
    identifiers.add(key);
    runs.push({
      runID: run.runID,
      inferenceFrames: run.inferenceFrames,
      ...(run.originalFrames === undefined ? {} : { originalFrames: run.originalFrames }),
    });
  }
  let runTimings: RecordingRunTiming[] | undefined;
  if (value.type === "pause" || value.runTimings !== undefined) {
    const parsed = validateRecordingRunTimings(value.runTimings, true);
    if (!parsed.ok) return parsed;
    if (
      parsed.value.length !== runs.length ||
      parsed.value.some((timing) => !identifiers.has(timing.runID.toLowerCase()))
    )
      return invalid("Closed run timings must cover exactly the supplied run endpoints.");
    runTimings = parsed.value;
  }
  let control: RecordingPauseRequest | RecordingStopRequest;
  if (value.type === "pause") {
    if (
      !runs.length ||
      runTimings === undefined ||
      (value.interruption !== undefined && typeof value.interruption !== "string")
    )
      return invalid("Pause requires closed run endpoints and an optional interruption message.");
    control = {
      type: "pause",
      epoch: value.epoch,
      runs,
      runTimings,
      ...(value.interruption === undefined ? {} : { interruption: value.interruption }),
    };
  } else {
    control = {
      type: "stop",
      epoch: value.epoch,
      runs,
      ...(runTimings === undefined ? {} : { runTimings }),
    };
  }
  if (Buffer.byteLength(JSON.stringify(control)) > MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES)
    return invalid("Recording control JSON exceeds the control size limit.");
  return { ok: true, value: control };
}

function validatePCM(header: RecordingAudioHeader, pcm: Uint8Array) {
  if (pcm.byteLength !== header.frameCount * header.format.channels * 4)
    return invalid("PCM length does not match the declared frame count and channels.");
  if (createHash("sha256").update(pcm).digest("hex") !== header.sha256)
    return invalid("PCM SHA-256 does not match its header.");
  const samples = new DataView(pcm.buffer, pcm.byteOffset, pcm.byteLength);
  for (let offset = 0; offset < pcm.byteLength; offset += 4)
    if (!Number.isFinite(samples.getFloat32(offset, true)))
      return invalid("PCM contains a non-finite float32 sample.");
  return { ok: true as const, value: { header, pcm } };
}

export function decodeRecordingAudioMessage(
  input: Uint8Array | ArrayBuffer,
): RecordingResult<RecordingAudioMessage> {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  if (bytes.byteLength < 4 || bytes.byteLength > MAXIMUM_RECORDING_MESSAGE_BYTES)
    return invalid("Binary recording message is truncated or exceeds the payload limit.");
  const headerLength = new DataView(bytes.buffer, bytes.byteOffset, 4).getUint32(0, false);
  if (
    headerLength === 0 ||
    headerLength > MAXIMUM_RECORDING_HEADER_BYTES ||
    headerLength + 4 > bytes.byteLength
  )
    return invalid("Binary recording message has an invalid JSON header length.");
  let raw: unknown;
  try {
    raw = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(4, 4 + headerLength)),
    );
  } catch {
    return invalid("Binary recording header is not valid UTF-8 JSON.");
  }
  const header = validateRecordingAudioHeader(raw);
  if (!header.ok) return header;
  return validatePCM(header.value, bytes.subarray(4 + headerLength));
}

export function encodeRecordingAudioMessage(
  header: RecordingAudioHeader,
  pcm: Uint8Array,
): RecordingResult<Uint8Array> {
  const validated = validateRecordingAudioHeader(header);
  if (!validated.ok) return validated;
  const audio = validatePCM(validated.value, pcm);
  if (!audio.ok) return audio;
  const json = new TextEncoder().encode(JSON.stringify(validated.value));
  if (json.byteLength > MAXIMUM_RECORDING_HEADER_BYTES)
    return invalid("Audio JSON header exceeds its size limit.");
  const message = new Uint8Array(4 + json.byteLength + pcm.byteLength);
  new DataView(message.buffer).setUint32(0, json.byteLength, false);
  message.set(json, 4);
  message.set(pcm, 4 + json.byteLength);
  return { ok: true, value: message };
}
