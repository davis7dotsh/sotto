import { constants } from "node:fs";
import { open, readdir, rm, statfs } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import type {
  AudioKind,
  AudioArtifact,
  AudioStreamFormat,
  CreateGenerationRequest,
  DeliveryReceipt,
  DictationContinuation,
  GenerationRecord,
  PreferencesSnapshot,
} from "./api.ts";
import {
  MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES,
  type RecordingAudioHeader,
  type RecordingSnapshot,
  type RecordingRunEndpoint,
  type RecordingAck,
  type RecordingPage,
  type RecordingRunTiming,
} from "./recording-contract.ts";

import type { InferenceBackend, SpeechInferenceResult } from "./inference/native-inference.ts";
import { ServiceError } from "./errors.ts";
import {
  selectSpeechWindow,
  absoluteSpeechSpans,
  reconcileSpeechBoundary,
  resolveSpeechBoundaryWithRedecode,
  partitionSpeechWindow,
  type TimedSpeechWindow,
} from "./inference/speech-windows.ts";
import {
  atomicPrivateWrite,
  ensureDirectory,
  readRegularFile,
  requireDiskSpace,
  requireRegularDirectory,
  sha256,
} from "./storage.ts";
import { validateBody } from "./validation.ts";
import { recognitionVocabularyTerms } from "./domain/dictionary.ts";
import { composeDictation } from "./domain/composition.ts";
import {
  createLongRecordingTextState,
  processLongRecordingTextWindow,
  finalizeLongRecordingText,
  drainLongRecordingTextSpans,
  longRecordingTextResult,
} from "./domain/long-recording-text.ts";

const MAX_CHUNK_BYTES = 1_048_576;
const WINDOW_FRAMES = 16_000 * 45;
const MAX_MANIFEST_BYTES = 2 * 1024 * 1024;
const uuid = () => randomUUID().toUpperCase();
const date = () => new Date().toISOString();
const copy = <T>(value: T): T => structuredClone(value);
const isUUID = (value: string) =>
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const integer = (value: number) => Number.isSafeInteger(value) && value >= 0;
const failure = (code: string, message: string, status = 409) =>
  new ServiceError(status, code, message);
type TextState = ReturnType<typeof createLongRecordingTextState>;
type TextSpan = ReturnType<typeof drainLongRecordingTextSpans>[number];
interface Manifest {
  version: 2;
  snapshot: RecordingSnapshot;
  cursors: {
    runID: string;
    frameCount: number;
    transcribedFrames: number;
    proofreadFrames: number;
    pending?: TimedSpeechWindow;
  }[];
  nextWindow: number;
  textState: TextState;
  previous?: DictationContinuation;
}
interface Receipt {
  runID: string;
  kind: AudioKind;
  sequence: number;
  firstFrame: number;
  frameCount: number;
  format: AudioStreamFormat;
  sha256: string;
}
interface ChunkPosition {
  sequence: number;
  firstFrame: number;
  frameCount: number;
}
interface WindowRecord {
  runID: string;
  firstFrame: number;
  frameCount: number;
  speech: SpeechInferenceResult;
  spans: TextSpan[];
}
interface Configuration {
  dataDirectory: string;
  development: boolean;
}
interface Hooks {
  getPreferences: () => Promise<PreferencesSnapshot>;
  admit?: () => Promise<void>;
  resolveContinuation?: (
    id: string,
    snapshot: RecordingSnapshot,
  ) => Promise<DictationContinuation | undefined>;
}

/** Receipts and audio are durable before ACK. Model work never holds the mutation queue. */
export class RecordingService {
  private readonly sessions = new Map<string, Manifest>();
  private readonly chunks = new Map<string, ChunkPosition[]>();
  private readonly subscribers = new Map<string, Set<(snapshot: RecordingSnapshot) => void>>();
  private queue: Promise<unknown> = Promise.resolve();
  private worker?: Promise<void>;
  private wakeRequested = false;
  private stopping = false;
  private readonly controller = new AbortController();
  private readonly jobs = new Map<string, AbortController>();
  private constructor(
    private readonly configuration: Configuration,
    private readonly inference: InferenceBackend,
    private readonly hooks: Hooks,
  ) {}

  static async open(configuration: Configuration, inference: InferenceBackend, hooks: Hooks) {
    const service = new RecordingService(configuration, inference, hooks);
    await ensureDirectory(configuration.dataDirectory);
    await ensureDirectory(service.root);
    await service.syncDirectory(configuration.dataDirectory);
    for (const id of await readdir(service.root)) {
      if (!isUUID(id)) continue;
      const directory = join(service.root, id);
      await requireRegularDirectory(directory);
      let data: Buffer;
      try {
        data = await readRegularFile(join(directory, "manifest.json"), MAX_MANIFEST_BYTES);
      } catch (error) {
        // Admission wasn't acknowledged until its first manifest was committed.
        if (error instanceof Error && "code" in error && error.code === "ENOENT") continue;
        throw error;
      }
      const parsed: unknown = JSON.parse(data.toString());
      if (!parsed || typeof parsed !== "object" || !("version" in parsed) || parsed.version !== 2)
        throw failure("invalid_archive", "Unsupported recording session archive.", 500);
      const manifest = parsed as Manifest;
      if (
        manifest.snapshot.id !== id ||
        !Array.isArray(manifest.snapshot.streams) ||
        !Array.isArray(manifest.cursors)
      )
        throw failure("invalid_archive", "Invalid recording session manifest.", 500);
      // A socket never survives process restart; fence every previous connection.
      manifest.snapshot.epoch++;
      if (manifest.snapshot.captureState === "recording")
        manifest.snapshot.captureState = "interrupted";
      if (manifest.snapshot.captureState === "discarded") {
        manifest.snapshot.streams = [];
        manifest.cursors = [];
        manifest.textState = createLongRecordingTextState();
        manifest.nextWindow = 0;
        delete manifest.previous;
        manifest.snapshot.previewText = "";
      }
      for (const stream of manifest.snapshot.streams) {
        if (!isUUID(stream.runID))
          throw failure("invalid_archive", "Invalid capture run in archive.", 500);
        const positions: ChunkPosition[] = [];
        let sequence = 0,
          frameCount = 0;
        while (true) {
          const path = service.chunkPath(id, stream.runID, stream.kind, sequence, "json");
          let receipt: Receipt;
          try {
            receipt = JSON.parse((await readRegularFile(path, 4096)).toString()) as Receipt;
          } catch (error) {
            if (error instanceof Error && "code" in error && error.code === "ENOENT") break;
            throw error;
          }
          if (
            receipt.sequence !== sequence ||
            receipt.firstFrame !== frameCount ||
            receipt.runID !== stream.runID ||
            receipt.kind !== stream.kind ||
            !integer(receipt.frameCount) ||
            receipt.frameCount === 0 ||
            JSON.stringify(receipt.format) !== JSON.stringify(stream.format)
          )
            throw failure("invalid_archive", "Noncontiguous recording receipt journal.", 500);
          const file = await open(
            service.chunkPath(id, stream.runID, stream.kind, sequence, "pcm"),
            constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
          );
          try {
            const info = await file.stat();
            if (!info.isFile() || info.size !== receipt.frameCount * stream.format.channels * 4)
              throw failure("invalid_archive", "Acknowledged audio is missing or damaged.", 500);
          } finally {
            await file.close();
          }
          positions.push({ sequence, firstFrame: frameCount, frameCount: receipt.frameCount });
          frameCount += receipt.frameCount;
          sequence++;
        }
        if (sequence < stream.nextSequence || frameCount < stream.frameCount)
          throw failure("invalid_archive", "Acknowledged recording audio is missing.", 500);
        stream.nextSequence = sequence;
        stream.frameCount = frameCount;
        service.chunks.set(service.streamKey(id, stream.runID, stream.kind), positions);
      }
      manifest.snapshot.uploadedFrames = service.uploaded(manifest);
      if (
        manifest.snapshot.processingState !== "completed" &&
        manifest.snapshot.captureState !== "discarded"
      ) {
        manifest.snapshot.processingState = "queued";
        delete manifest.snapshot.error;
      }
      await service.commit(manifest);
      if (manifest.snapshot.captureState === "discarded") await service.pruneDiscarded(id);
    }
    service.schedule();
    return service;
  }

  private get root() {
    return join(this.configuration.dataDirectory, "sessions");
  }
  private directory(id: string) {
    return join(this.root, id);
  }
  private async syncDirectory(path: string) {
    const directory = await open(
      path,
      constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
    );
    try {
      await directory.sync();
    } finally {
      await directory.close();
    }
  }
  private streamKey(id: string, runID: string, kind: AudioKind) {
    return `${id}/${runID}/${kind}`;
  }
  private chunkDirectory(id: string, runID: string, kind: AudioKind) {
    return join(this.directory(id), runID, kind);
  }
  private chunkPath(
    id: string,
    runID: string,
    kind: AudioKind,
    sequence: number,
    extension: string,
  ) {
    return join(this.chunkDirectory(id, runID, kind), `${sequence}.${extension}`);
  }
  private mutate<T>(fn: () => T | Promise<T>) {
    const task = this.queue.then(fn);
    this.queue = task.catch(() => {});
    return task;
  }
  private lookup(id: string) {
    const manifest = this.sessions.get(id.toUpperCase());
    if (!manifest) throw failure("recording_not_found", "Recording not found.", 404);
    return manifest;
  }
  private async commit(manifest: Manifest) {
    const data = JSON.stringify(manifest);
    if (Buffer.byteLength(data) > MAX_MANIFEST_BYTES)
      throw failure(
        "metadata_too_large",
        "Recording checkpoint exceeded its bounded storage budget.",
        413,
      );
    manifest.snapshot.revision++;
    await atomicPrivateWrite(
      join(this.directory(manifest.snapshot.id), "manifest.json"),
      JSON.stringify(manifest),
    );
    this.sessions.set(manifest.snapshot.id, copy(manifest));
    for (const callback of this.subscribers.get(manifest.snapshot.id) ?? []) {
      try {
        callback(copy(manifest.snapshot));
      } catch {}
    }
  }
  private uploaded(manifest: Manifest) {
    return manifest.snapshot.streams
      .filter((stream) => stream.kind === "inference")
      .reduce((sum, stream) => sum + stream.frameCount, 0);
  }
  private assertEpoch(manifest: Manifest, epoch: number) {
    if (!Number.isSafeInteger(epoch) || epoch < 1 || epoch !== manifest.snapshot.epoch)
      throw failure("stale_epoch", "Reconnect before sending recording audio or controls.");
    if (manifest.snapshot.captureState === "discarded")
      throw failure("recording_discarded", "This recording was explicitly discarded.");
  }
  private assertRunning() {
    if (this.stopping)
      throw failure(
        "server_stopping",
        "The server is shutting down. Recorded audio remains preserved.",
        503,
      );
  }
  subscribe(id: string, callback: (snapshot: RecordingSnapshot) => void) {
    const key = this.lookup(id).snapshot.id;
    const callbacks = this.subscribers.get(key) ?? new Set();
    callbacks.add(callback);
    this.subscribers.set(key, callbacks);
    return () => {
      callbacks.delete(callback);
      if (!callbacks.size) this.subscribers.delete(key);
    };
  }
  async create(request: CreateGenerationRequest) {
    validateBody("CreateGenerationRequest", request);
    return this.mutate(async () => {
      if (this.stopping) throw failure("server_stopping", "The server is shutting down.", 503);
      const existing = [...this.sessions.values()].find(
        ({ snapshot }) =>
          snapshot.requestID === request.requestID.toUpperCase() &&
          snapshot.device.id === request.device.id,
      );
      if (existing) return copy(existing.snapshot);
      await this.hooks.admit?.();
      await requireDiskSpace(this.configuration.dataDirectory);
      const settings = await this.hooks.getPreferences();
      const id = uuid();
      await ensureDirectory(this.directory(id));
      await this.syncDirectory(this.root);
      await ensureDirectory(join(this.directory(id), "windows"));
      const manifest: Manifest = {
        version: 2,
        snapshot: {
          id,
          requestID: request.requestID.toUpperCase(),
          device: copy(request.device),
          mode: request.mode,
          settings: copy(settings),
          createdAt: date(),
          revision: 0,
          captureState: "recording",
          processingState: "queued",
          uploadedFrames: 0,
          transcribedFrames: 0,
          proofreadFrames: 0,
          streams: [],
          epoch: 0,
          previewText: "",
        },
        cursors: [],
        nextWindow: 0,
        textState: createLongRecordingTextState(),
      };
      await this.commit(manifest);
      return copy(manifest.snapshot);
    });
  }
  get(id: string) {
    return this.mutate(() => copy(this.lookup(id).snapshot));
  }
  resume(id: string) {
    return this.mutate(async () => {
      this.assertRunning();
      const manifest = copy(this.lookup(id));
      if (manifest.snapshot.captureState === "discarded")
        throw failure("recording_discarded", "This recording was discarded.");
      manifest.snapshot.epoch++;
      if (manifest.snapshot.processingState === "failed") {
        manifest.snapshot.processingState = "queued";
        delete manifest.snapshot.error;
      }
      await this.commit(manifest);
      this.schedule();
      return copy(manifest.snapshot);
    });
  }
  setContinuation(id: string, epoch: number, continuationID: string) {
    return this.mutate(async () => {
      this.assertRunning();
      const manifest = copy(this.lookup(id));
      this.assertEpoch(manifest, epoch);
      if (!isUUID(continuationID))
        throw failure("invalid_context", "Continuation must identify a previous recording.", 400);
      continuationID = continuationID.toUpperCase();
      if (manifest.snapshot.continuationID) {
        if (manifest.snapshot.continuationID !== continuationID)
          throw failure("context_conflict", "Recording continuation is already fixed.");
        return copy(manifest.snapshot);
      }
      if (
        manifest.snapshot.streams.length > 0 ||
        manifest.nextWindow > 0 ||
        manifest.snapshot.processingState === "processing"
      )
        throw failure("context_too_late", "Set continuation before uploading audio.");
      let previous: DictationContinuation | undefined;
      const local = this.sessions.get(continuationID);
      if (local && local.snapshot.processingState === "completed") {
        const result = JSON.parse(
          (
            await readRegularFile(
              join(this.directory(continuationID), "result.json"),
              64 * 1024 * 1024,
            )
          ).toString(),
        ) as GenerationRecord;
        const age = Date.parse(manifest.snapshot.createdAt) - Date.parse(result.updatedAt);
        if (
          result.device.id === manifest.snapshot.device.id &&
          result.mode === manifest.snapshot.mode &&
          age >= 0 &&
          age < 900000 &&
          (result.mode === "test" ||
            ["inserted", "listUpdated"].includes(result.delivery?.status ?? ""))
        )
          previous = result.continuation;
      } else {
        previous = await this.hooks.resolveContinuation?.(continuationID, copy(manifest.snapshot));
      }
      // An expired or no-longer-valid destination starts fresh, like legacy dictation.
      manifest.snapshot.continuationID = continuationID;
      manifest.previous = copy(previous);
      manifest.textState = createLongRecordingTextState(previous?.list);
      await this.commit(manifest);
      return copy(manifest.snapshot);
    });
  }
  setContext(id: string, epoch: number, continuationID: string) {
    return this.setContinuation(id, epoch, continuationID);
  }
  appendAudio(id: string, header: RecordingAudioHeader, bytes: Buffer) {
    // Reject invalid input before allocating another copy or entering the disk queue.
    this.validateAudio(header, bytes);
    header = {
      ...header,
      runID: header.runID.toUpperCase(),
      format: { sampleRate: header.format.sampleRate, channels: header.format.channels },
    };
    return this.mutate(async () => {
      this.assertRunning();
      const manifest = copy(this.lookup(id));
      id = manifest.snapshot.id;
      this.assertEpoch(manifest, header.epoch);
      if (header.kind === "original" && !manifest.snapshot.settings.preferences.keepOriginalAudio)
        throw failure("original_disabled", "Original audio retention is disabled.", 400);
      let stream = manifest.snapshot.streams.find(
        (stream) => stream.runID === header.runID && stream.kind === header.kind,
      );
      if (!stream) {
        if (header.sequence !== 0 || header.firstFrame !== 0)
          throw failure(
            "noncontiguous_audio",
            "A new audio stream must start at frame and sequence zero.",
          );
        await ensureDirectory(join(this.directory(id), header.runID));
        await ensureDirectory(this.chunkDirectory(id, header.runID, header.kind));
        await this.syncDirectory(join(this.directory(id), header.runID));
        stream = {
          runID: header.runID,
          kind: header.kind,
          format: copy(header.format),
          nextSequence: 0,
          frameCount: 0,
        };
        manifest.snapshot.streams.push(stream);
        if (header.kind === "inference")
          manifest.cursors.push({
            runID: header.runID,
            frameCount: 0,
            transcribedFrames: 0,
            proofreadFrames: 0,
          });
      }
      if (JSON.stringify(stream.format) !== JSON.stringify(header.format))
        throw failure("format_changed", "An audio stream cannot change format.");
      const endpoint = (manifest.snapshot.stopRuns ?? manifest.snapshot.closedRuns)?.find(
        (run) => run.runID === header.runID,
      );
      if (
        (manifest.snapshot.stopRuns || endpoint) &&
        (!endpoint ||
          header.firstFrame + header.frameCount >
            (header.kind === "inference"
              ? endpoint.inferenceFrames
              : (endpoint.originalFrames ?? 0)))
      )
        throw failure("audio_past_stop", "Audio exceeds the accepted stop endpoint.");
      const receipt: Receipt = {
        runID: header.runID,
        kind: header.kind,
        sequence: header.sequence,
        firstFrame: header.firstFrame,
        frameCount: header.frameCount,
        format: copy(header.format),
        sha256: header.sha256,
      };
      if (header.sequence < stream.nextSequence) {
        const saved = JSON.parse(
          (
            await readRegularFile(
              this.chunkPath(id, header.runID, header.kind, header.sequence, "json"),
              4096,
            )
          ).toString(),
        ) as Receipt;
        if (JSON.stringify(saved) !== JSON.stringify(receipt))
          throw failure("conflicting_audio", "This sequence already contains different audio.");
        return this.ack(manifest, stream);
      }
      if (manifest.snapshot.processingState === "completed")
        throw failure("upload_closed", "Recording processing has completed.");
      if (header.sequence !== stream.nextSequence || header.firstFrame !== stream.frameCount)
        throw failure(
          "noncontiguous_audio",
          "Audio must follow the server's durable stream position.",
        );
      if (!integer(stream.frameCount + header.frameCount) || !integer(stream.nextSequence + 1))
        throw failure("audio_overflow", "Audio position exceeds safe integer precision.", 413);
      await requireDiskSpace(this.configuration.dataDirectory);
      try {
        const saved = JSON.parse(
          (
            await readRegularFile(
              this.chunkPath(id, header.runID, header.kind, header.sequence, "json"),
              4096,
            )
          ).toString(),
        ) as Receipt;
        if (JSON.stringify(saved) !== JSON.stringify(receipt))
          throw failure(
            "conflicting_audio",
            "This sequence already contains different committed audio.",
          );
      } catch (error) {
        if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) throw error;
      }
      // An uncommitted PCM file from a crash is safe to replace. A receipt is the commit marker.
      await atomicPrivateWrite(
        this.chunkPath(id, header.runID, header.kind, header.sequence, "pcm"),
        bytes,
      );
      await atomicPrivateWrite(
        this.chunkPath(id, header.runID, header.kind, header.sequence, "json"),
        JSON.stringify(receipt),
      );
      stream.nextSequence++;
      stream.frameCount += header.frameCount;
      manifest.snapshot.uploadedFrames = this.uploaded(manifest);
      if (
        !manifest.snapshot.stopRuns &&
        !manifest.snapshot.closedRuns?.some((run) => run.runID === header.runID)
      ) {
        manifest.snapshot.captureState = "recording";
        if (manifest.snapshot.processingState !== "failed") delete manifest.snapshot.error;
      }
      await this.commit(manifest);
      const key = this.streamKey(id, header.runID, header.kind);
      const positions = this.chunks.get(key) ?? [];
      positions.push({
        sequence: header.sequence,
        firstFrame: header.firstFrame,
        frameCount: header.frameCount,
      });
      this.chunks.set(key, positions);
      this.schedule();
      return this.ack(manifest, stream);
    });
  }
  private ack(manifest: Manifest, stream: RecordingSnapshot["streams"][number]): RecordingAck {
    return {
      type: "ack",
      runID: stream.runID,
      kind: stream.kind,
      nextSequence: stream.nextSequence,
      frameCount: stream.frameCount,
      revision: manifest.snapshot.revision,
    };
  }
  private validateAudio(header: RecordingAudioHeader, bytes: Buffer) {
    const format = header.format;
    if (
      !isUUID(header.runID) ||
      !["inference", "original"].includes(header.kind) ||
      !integer(header.sequence) ||
      !integer(header.firstFrame) ||
      !integer(header.frameCount) ||
      header.frameCount === 0 ||
      !format ||
      !Number.isInteger(format.sampleRate) ||
      format.sampleRate < 8000 ||
      format.sampleRate > 192000 ||
      !Number.isInteger(format.channels) ||
      format.channels < 1 ||
      format.channels > 8 ||
      (header.kind === "inference" && (format.sampleRate !== 16000 || format.channels !== 1)) ||
      !/^[a-f0-9]{64}$/.test(header.sha256) ||
      bytes.length === 0 ||
      bytes.length > MAX_CHUNK_BYTES ||
      bytes.length !== header.frameCount * format.channels * 4 ||
      sha256(bytes) !== header.sha256
    )
      throw failure("invalid_audio", "Audio metadata, checksum or payload is invalid.", 400);
    for (let offset = 0; offset < bytes.length; offset += 4)
      if (!Number.isFinite(bytes.readFloatLE(offset)))
        throw failure("invalid_audio", "Audio contains nonfinite samples.", 400);
  }
  private normalizeEndpoints(manifest: Manifest, runs: RecordingRunEndpoint[]) {
    if (
      !Array.isArray(runs) ||
      !runs.length ||
      Buffer.byteLength(JSON.stringify(runs)) > MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES ||
      new Set(runs.map((run) => run.runID)).size !== runs.length ||
      runs.some(
        (run) =>
          !isUUID(run.runID) ||
          !integer(run.inferenceFrames) ||
          (run.originalFrames !== undefined && !integer(run.originalFrames)),
      )
    )
      throw failure(
        "invalid_stop",
        "Stop requires exact nonnegative endpoints for each capture run.",
        400,
      );
    const totals = copy(runs)
      .map((run) => ({
        runID: run.runID.toUpperCase(),
        inferenceFrames: run.inferenceFrames,
        ...(run.originalFrames === undefined ? {} : { originalFrames: run.originalFrames }),
      }))
      .sort((a, b) => a.runID.localeCompare(b.runID));
    if (new Set(totals.map((run) => run.runID)).size !== totals.length)
      throw failure("invalid_stop", "Capture run identities must be distinct.", 400);
    for (const run of totals) {
      const keep = manifest.snapshot.settings.preferences.keepOriginalAudio;
      if (
        (keep && run.inferenceFrames > 0 && run.originalFrames === undefined) ||
        (!keep && run.originalFrames !== undefined)
      )
        throw failure(
          "invalid_stop",
          "Stop endpoints must match the accepted original-audio retention settings.",
          400,
        );
      const original = manifest.snapshot.streams.find(
        (stream) => stream.runID === run.runID && stream.kind === "original",
      );
      if (
        original &&
        run.originalFrames !== undefined &&
        Math.abs(run.inferenceFrames / 16000 - run.originalFrames / original.format.sampleRate) >
          0.25
      )
        throw failure(
          "invalid_stop",
          "Original and inference audio endpoints must describe the same duration.",
          400,
        );
    }
    return totals;
  }
  private mergeTimings(
    manifest: Manifest,
    timings: RecordingRunTiming[],
    endpoints: RecordingRunEndpoint[],
    requireAll: boolean,
  ) {
    if (
      !Array.isArray(timings) ||
      Buffer.byteLength(JSON.stringify(timings)) > MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES
    )
      throw failure("invalid_timing", "Capture timings exceed the control budget.", 400);
    const normalized = timings.map((timing) => ({
      runID: timing.runID.toUpperCase(),
      startedAt: timing.startedAt,
      endedAt: timing.endedAt,
      ...(timing.gapBeforeMilliseconds === undefined
        ? {}
        : { gapBeforeMilliseconds: timing.gapBeforeMilliseconds }),
    }));
    if (
      new Set(normalized.map((timing) => timing.runID)).size !== normalized.length ||
      normalized.some(
        (timing) =>
          !isUUID(timing.runID) ||
          !Number.isFinite(Date.parse(timing.startedAt)) ||
          !timing.endedAt ||
          !Number.isFinite(Date.parse(timing.endedAt)) ||
          Date.parse(timing.endedAt) < Date.parse(timing.startedAt) ||
          (timing.gapBeforeMilliseconds !== undefined && !integer(timing.gapBeforeMilliseconds)) ||
          !endpoints.some((run) => run.runID === timing.runID),
      ) ||
      (requireAll && normalized.length !== endpoints.length)
    )
      throw failure(
        "invalid_timing",
        "Each closed run requires its actual start and end capture time.",
        400,
      );
    const merged = copy(manifest.snapshot.runTimings ?? []);
    for (const timing of normalized) {
      const existing = merged.find((value) => value.runID === timing.runID);
      if (existing && JSON.stringify(existing) !== JSON.stringify(timing))
        throw failure("timing_conflict", "Closed capture timing is immutable.");
      if (!existing) merged.push(timing);
    }
    manifest.snapshot.runTimings = merged.sort(
      (a, b) => Date.parse(a.startedAt) - Date.parse(b.startedAt) || a.runID.localeCompare(b.runID),
    );
  }
  pause(
    id: string,
    epoch: number,
    runs: RecordingRunEndpoint[],
    runTimings: RecordingRunTiming[],
    interruption?: string,
  ) {
    return this.mutate(async () => {
      this.assertRunning();
      const manifest = copy(this.lookup(id));
      this.assertEpoch(manifest, epoch);
      if (manifest.snapshot.stopRuns || manifest.snapshot.processingState === "completed")
        throw failure("recording_stopped", "A stopped recording cannot be paused or resumed.");
      if (
        interruption !== undefined &&
        (typeof interruption !== "string" || Buffer.byteLength(interruption) > 4096)
      )
        throw failure("invalid_interruption", "The interruption reason is too large.", 400);
      const totals = this.normalizeEndpoints(manifest, runs);
      this.mergeTimings(manifest, runTimings, totals, true);
      const closed = copy(manifest.snapshot.closedRuns ?? []);
      let changed = false;
      for (const run of totals) {
        const existing = closed.find((value) => value.runID === run.runID);
        if (existing && JSON.stringify(existing) !== JSON.stringify(run))
          throw failure("pause_conflict", "Paused capture endpoints are immutable.");
        if (!existing) {
          closed.push(run);
          changed = true;
        }
        for (const stream of manifest.snapshot.streams.filter(
          (stream) => stream.runID === run.runID,
        )) {
          const end = stream.kind === "inference" ? run.inferenceFrames : run.originalFrames;
          if (end === undefined || stream.frameCount > end)
            throw failure(
              "invalid_pause",
              "Paused endpoints cannot shorten acknowledged audio.",
              400,
            );
        }
      }
      if (!changed) return copy(this.lookup(id).snapshot);
      manifest.snapshot.closedRuns = closed.sort((a, b) => {
        const at = manifest.snapshot.runTimings?.find(
          (timing) => timing.runID === a.runID,
        )?.startedAt;
        const bt = manifest.snapshot.runTimings?.find(
          (timing) => timing.runID === b.runID,
        )?.startedAt;
        return at && bt ? Date.parse(at) - Date.parse(bt) : 0;
      });
      manifest.snapshot.captureState = "interrupted";
      if (interruption && manifest.snapshot.processingState !== "failed")
        manifest.snapshot.error = interruption;
      await this.commit(manifest);
      this.schedule();
      return copy(manifest.snapshot);
    });
  }
  stop(id: string, epoch: number, runs: RecordingRunEndpoint[], runTimings?: RecordingRunTiming[]) {
    return this.mutate(async () => {
      this.assertRunning();
      const manifest = copy(this.lookup(id));
      this.assertEpoch(manifest, epoch);
      const totals = this.normalizeEndpoints(manifest, runs);
      for (const closed of manifest.snapshot.closedRuns ?? []) {
        const endpoint = totals.find((run) => run.runID === closed.runID);
        if (!endpoint || JSON.stringify(endpoint) !== JSON.stringify(closed))
          throw failure(
            "stop_conflict",
            "Final stop must include every immutable paused endpoint.",
          );
      }
      if (manifest.snapshot.stopRuns) {
        if (JSON.stringify(manifest.snapshot.stopRuns) !== JSON.stringify(totals))
          throw failure("stop_conflict", "The accepted stop endpoints are immutable.");
        if (runTimings) {
          const existing = JSON.stringify(manifest.snapshot.runTimings ?? []);
          this.mergeTimings(manifest, runTimings, totals, true);
          if (JSON.stringify(manifest.snapshot.runTimings) !== existing)
            throw failure("timing_conflict", "Final stop timing is already immutable.");
        }
        return copy(manifest.snapshot);
      }
      if (runTimings) this.mergeTimings(manifest, runTimings, totals, true);
      for (const stream of manifest.snapshot.streams) {
        const run = totals.find((run) => run.runID === stream.runID);
        const end = stream.kind === "inference" ? run?.inferenceFrames : run?.originalFrames;
        if (end === undefined || end < stream.frameCount)
          throw failure(
            "invalid_stop",
            "Stop endpoints cannot omit or shorten acknowledged audio.",
            400,
          );
      }
      manifest.snapshot.stopRuns = totals;
      manifest.snapshot.captureState = "stopped";
      if (manifest.snapshot.processingState === "failed") {
        manifest.snapshot.processingState = "queued";
        delete manifest.snapshot.error;
      }
      await this.commit(manifest);
      this.schedule();
      return copy(manifest.snapshot);
    });
  }
  interrupt(id: string, epoch: number) {
    return this.mutate(async () => {
      const manifest = copy(this.lookup(id));
      if (this.stopping) return copy(manifest.snapshot);
      this.assertEpoch(manifest, epoch);
      if (!manifest.snapshot.stopRuns) {
        manifest.snapshot.captureState = "interrupted";
        await this.commit(manifest);
      }
      return copy(manifest.snapshot);
    });
  }
  discard(id: string) {
    return this.mutate(async () => {
      this.assertRunning();
      const manifest = copy(this.lookup(id));
      if (manifest.snapshot.captureState !== "discarded") {
        manifest.snapshot.captureState = "discarded";
        manifest.snapshot.processingState = "failed";
        manifest.snapshot.error = "Recording explicitly discarded.";
        for (const stream of manifest.snapshot.streams)
          this.chunks.delete(this.streamKey(manifest.snapshot.id, stream.runID, stream.kind));
        manifest.snapshot.streams = [];
        manifest.cursors = [];
        manifest.textState = createLongRecordingTextState();
        manifest.nextWindow = 0;
        manifest.snapshot.previewText = "";
        delete manifest.previous;
        await this.commit(manifest);
      }
      this.jobs.get(manifest.snapshot.id)?.abort();
      await this.pruneDiscarded(manifest.snapshot.id);
      return copy(manifest.snapshot);
    });
  }
  private async pruneDiscarded(id: string) {
    await requireRegularDirectory(this.directory(id));
    for (const name of await readdir(this.directory(id))) {
      if (isUUID(name) || name === "windows") {
        const directory = join(this.directory(id), name);
        await requireRegularDirectory(directory);
        await rm(directory, { recursive: true });
      } else if (["result.json", "transcript.txt", "window.wav"].includes(name)) {
        await rm(join(this.directory(id), name), { force: true });
      }
    }
    await this.syncDirectory(this.directory(id));
  }

  private schedule() {
    if (this.stopping) return;
    this.wakeRequested = true;
    if (this.worker) return;
    this.worker = Promise.resolve()
      .then(async () => {
        while (this.wakeRequested && !this.stopping) {
          this.wakeRequested = false;
          let progressed = true;
          while (progressed && !this.stopping) {
            progressed = false;
            for (const id of this.sessions.keys()) {
              if (this.stopping) break;
              if (await this.processNext(id)) progressed = true;
            }
          }
        }
      })
      .catch(() => {
        // A checkpoint/storage failure must not delete audio or escape as an
        // unhandled background rejection. A later explicit resume retries it.
      })
      .finally(() => {
        this.worker = undefined;
        if (this.wakeRequested && !this.stopping) this.schedule();
      });
  }
  private readyToComplete(manifest: Manifest) {
    const { stopRuns, streams } = manifest.snapshot;
    return (
      !!stopRuns &&
      stopRuns.every((run) => {
        const inference = streams.find(
          (stream) => stream.runID === run.runID && stream.kind === "inference",
        );
        const original = streams.find(
          (stream) => stream.runID === run.runID && stream.kind === "original",
        );
        return (
          (inference?.frameCount ?? 0) === run.inferenceFrames &&
          (run.originalFrames === undefined ||
            (original?.frameCount ?? 0) === run.originalFrames) &&
          (manifest.cursors.find((cursor) => cursor.runID === run.runID)?.frameCount ?? 0) ===
            run.inferenceFrames
        );
      })
    );
  }
  private async processNext(id: string) {
    const work = await this.mutate(async () => {
      const manifest = copy(this.lookup(id));
      if (
        manifest.snapshot.captureState === "discarded" ||
        ["completed", "failed"].includes(manifest.snapshot.processingState)
      )
        return undefined;
      const streams = manifest.snapshot.streams.filter((stream) => stream.kind === "inference");
      const closedOrder = (manifest.snapshot.closedRuns ?? []).map((run) => run.runID);
      streams.sort((a, b) => {
        const ai = closedOrder.indexOf(a.runID),
          bi = closedOrder.indexOf(b.runID);
        if (ai !== -1 || bi !== -1)
          return (ai === -1 ? closedOrder.length : ai) - (bi === -1 ? closedOrder.length : bi);
        return 0;
      });
      for (const closed of manifest.snapshot.closedRuns ?? []) {
        if (closed.inferenceFrames > 0 && !streams.some((stream) => stream.runID === closed.runID))
          return undefined;
      }
      for (const run of manifest.snapshot.stopRuns ?? manifest.snapshot.closedRuns ?? []) {
        const original = manifest.snapshot.streams.find(
          (stream) => stream.kind === "original" && stream.runID === run.runID,
        );
        if (
          original &&
          run.originalFrames !== undefined &&
          Math.abs(run.inferenceFrames / 16000 - run.originalFrames / original.format.sampleRate) >
            0.25
        ) {
          manifest.snapshot.processingState = "failed";
          manifest.snapshot.error =
            "Original and inference audio endpoints have different durations. Captured audio has been preserved.";
          await this.commit(manifest);
          return undefined;
        }
      }
      for (const stream of streams) {
        const cursor = manifest.cursors.find((cursor) => cursor.runID === stream.runID)!;
        const available = stream.frameCount - cursor.frameCount;
        const endpoint = (manifest.snapshot.stopRuns ?? manifest.snapshot.closedRuns)?.find(
          (run) => run.runID === stream.runID,
        )?.inferenceFrames;
        const ended =
          (endpoint !== undefined && stream.frameCount === endpoint) ||
          (endpoint === undefined && streams.indexOf(stream) < streams.length - 1);
        if (ended && cursor.pending && cursor.pending.endFrame === stream.frameCount) {
          return {
            manifest,
            runID: stream.runID,
            firstFrame: cursor.frameCount,
            frameCount: 0,
            final: true,
            flush: true,
            finalize: false,
          };
        }
        if (available >= WINDOW_FRAMES || (ended && available > 0)) {
          manifest.snapshot.processingState = "processing";
          await this.commit(manifest);
          return {
            manifest,
            runID: stream.runID,
            firstFrame: cursor.frameCount,
            frameCount: Math.min(available, WINDOW_FRAMES),
            final: ended && available <= WINDOW_FRAMES,
            finalize: false,
          };
        }
        // Maintain explicit run order: later runs cannot leapfrog an unfinished earlier tail.
        if (available > 0 || (endpoint !== undefined && cursor.frameCount < endpoint))
          return undefined;
      }
      if (this.readyToComplete(manifest)) {
        manifest.snapshot.processingState = "processing";
        await this.commit(manifest);
        return { manifest, runID: "", firstFrame: 0, frameCount: 0, final: true, finalize: true };
      }
      return undefined;
    });
    if (!work) return false;
    const job = new AbortController();
    this.jobs.set(id, job);
    const signal = AbortSignal.any([this.controller.signal, job.signal]);
    try {
      if (work.finalize) {
        const textState = await finalizeLongRecordingText(
          copy(work.manifest.textState),
          work.manifest.snapshot.settings.preferences,
          this.inference,
          signal,
        );
        const spans = drainLongRecordingTextSpans(textState);
        await this.mutate(async () => {
          const manifest = copy(this.lookup(id));
          if (manifest.snapshot.captureState === "discarded") return;
          if (!this.readyToComplete(manifest)) return;
          await atomicPrivateWrite(
            join(this.directory(id), "windows", `${manifest.nextWindow}.json`),
            JSON.stringify({ spans, final: true }),
          );
          manifest.textState = textState;
          manifest.nextWindow++;
          const assembled = await this.assembleText(manifest);
          const composition = composeDictation(assembled.formatted, manifest.previous);
          const result: GenerationRecord = {
            schemaVersion: 1,
            id,
            requestID: manifest.snapshot.requestID,
            device: copy(manifest.snapshot.device),
            mode: manifest.snapshot.mode,
            status: "completed",
            createdAt: manifest.snapshot.createdAt,
            updatedAt: date(),
            settings: copy(manifest.snapshot.settings),
            rawText: assembled.rawText,
            finalText: assembled.cleanedText,
            insertionText: composition.insertion,
            previewText: composition.preview,
            continuation: composition.continuation,
            formattingRejectionReason: assembled.formatted.formattingRejectionReason,
            inferenceAudio: this.audioMetadata(manifest.snapshot, "inference"),
            originalAudio: this.audioMetadata(manifest.snapshot, "original"),
            detectedLanguage: assembled.speech?.language,
            speech: assembled.speech
              ? {
                  modelID: "whisper-large-v3-turbo",
                  modelSHA256: assembled.speech.modelSHA256,
                  backend: process.platform === "darwin" ? "whisper.cpp/Metal" : "whisper.cpp",
                  engineVersion: assembled.speech.engineVersion,
                  processingSeconds: assembled.speechSeconds,
                }
              : undefined,
          };
          await atomicPrivateWrite(join(this.directory(id), "transcript.txt"), result.finalText);
          await atomicPrivateWrite(join(this.directory(id), "result.json"), JSON.stringify(result));
          manifest.snapshot.processingState = "completed";
          manifest.snapshot.proofreadFrames = manifest.snapshot.transcribedFrames;
          manifest.snapshot.previewText = result.finalText.slice(-4096);
          delete manifest.snapshot.error;
          await this.commit(manifest);
        });
      } else if ("flush" in work && work.flush) {
        const cursor = work.manifest.cursors.find((cursor) => cursor.runID === work.runID)!;
        const pending = cursor.pending!;
        const textState = await processLongRecordingTextWindow(
          copy(work.manifest.textState),
          pending.text,
          work.manifest.snapshot.settings.preferences,
          this.inference,
          signal,
        );
        const spans = drainLongRecordingTextSpans(textState);
        await this.mutate(async () => {
          const manifest = copy(this.lookup(id));
          if (manifest.snapshot.captureState === "discarded") return;
          await atomicPrivateWrite(
            join(this.directory(id), "windows", `${manifest.nextWindow}.json`),
            JSON.stringify({ spans, flush: true }),
          );
          manifest.nextWindow++;
          manifest.textState = textState;
          const updated = manifest.cursors.find((cursor) => cursor.runID === work.runID)!;
          updated.frameCount = pending.endFrame;
          updated.proofreadFrames = pending.endFrame;
          delete updated.pending;
          manifest.snapshot.proofreadFrames = manifest.cursors.reduce(
            (sum, value) => sum + value.proofreadFrames,
            0,
          );
          await this.commit(manifest);
        });
      } else {
        const bytes = await this.readAudioRange(
          id,
          work.runID,
          "inference",
          work.firstFrame,
          work.frameCount,
        );
        const wavPath = join(this.directory(id), "window.wav");
        signal.throwIfAborted();
        const settings = work.manifest.snapshot.settings.preferences;
        let selected = selectSpeechWindow({
          samples: new Float32Array(bytes.buffer, bytes.byteOffset, bytes.length / 4),
          startFrame: work.firstFrame,
          final: work.final,
          timedSpans: this.inference.timedSpeechSpans,
        });
        if (!selected)
          throw failure("invalid_window", "Speech scheduler selected an incomplete window.", 500);
        if (!work.final && this.inference.findSpeechBoundary) {
          await atomicPrivateWrite(
            wavPath,
            Buffer.concat([
              this.wavHeader(bytes.length, { sampleRate: 16000, channels: 1 }),
              bytes,
            ]),
          );
          const boundary = await this.inference.findSpeechBoundary(wavPath, signal);
          if (boundary !== undefined) {
            const offset = Math.round(boundary * 16000);
            if (
              !Number.isSafeInteger(offset) ||
              offset < 30 * 16000 ||
              offset > work.frameCount - 1600
            )
              throw failure(
                "invalid_boundary",
                "Speech boundary preflight returned an invalid interval.",
                500,
              );
            selected = {
              startFrame: work.firstFrame,
              endFrame: work.firstFrame + offset,
              nextStartFrame: work.firstFrame + offset,
              overlapFrames: 0,
              quietBoundary: true,
            };
          }
        }
        const selectedBytes = bytes.subarray(0, (selected.endFrame - selected.startFrame) * 4);
        await atomicPrivateWrite(
          wavPath,
          Buffer.concat([
            this.wavHeader(selectedBytes.length, { sampleRate: 16000, channels: 1 }),
            selectedBytes,
          ]),
        );
        let speech: SpeechInferenceResult;
        try {
          speech = await this.inference.transcribe(
            wavPath,
            settings.language,
            recognitionVocabularyTerms(settings.dictionary, settings.vocabulary),
            undefined,
            signal,
          );
        } finally {
          await rm(wavPath, { force: true });
        }
        signal.throwIfAborted();
        const cursor = work.manifest.cursors.find((cursor) => cursor.runID === work.runID)!;
        const current: TimedSpeechWindow = {
          startFrame: selected.startFrame,
          endFrame: selected.endFrame,
          text: speech.text,
          spans: speech.spans ? absoluteSpeechSpans(speech.spans, selected.startFrame) : undefined,
          segmentSpans: speech.segmentSpans
            ? absoluteSpeechSpans(speech.segmentSpans, selected.startFrame)
            : undefined,
        };
        let reconciled = current;
        if (cursor.pending) {
          let boundary = reconcileSpeechBoundary({ previous: cursor.pending, current });
          if (boundary.kind === "redecode") {
            const joinedBytes = await this.readAudioRange(
              id,
              work.runID,
              "inference",
              boundary.startFrame,
              boundary.endFrame - boundary.startFrame,
            );
            await atomicPrivateWrite(
              wavPath,
              Buffer.concat([
                this.wavHeader(joinedBytes.length, { sampleRate: 16000, channels: 1 }),
                joinedBytes,
              ]),
            );
            let joined: SpeechInferenceResult;
            try {
              joined = await this.inference.transcribe(
                wavPath,
                settings.language,
                recognitionVocabularyTerms(settings.dictionary, settings.vocabulary),
                undefined,
                signal,
              );
            } finally {
              await rm(wavPath, { force: true });
            }
            boundary = resolveSpeechBoundaryWithRedecode({
              previous: cursor.pending,
              current,
              redecoded: {
                startFrame: boundary.startFrame,
                endFrame: boundary.endFrame,
                text: joined.text,
                spans: joined.spans
                  ? absoluteSpeechSpans(joined.spans, boundary.startFrame)
                  : undefined,
                segmentSpans: joined.segmentSpans
                  ? absoluteSpeechSpans(joined.segmentSpans, boundary.startFrame)
                  : undefined,
              },
            });
          }
          if (boundary.kind !== "resolved")
            throw failure(
              "speech_boundary_unresolved",
              boundary.kind === "unresolved"
                ? boundary.reason
                : "Speech boundary remains unresolved.",
            );
          reconciled = {
            startFrame: cursor.pending.startFrame,
            endFrame: current.endFrame,
            text: boundary.text,
            spans: boundary.spans,
            segmentSpans: "segmentSpans" in boundary ? boundary.segmentSpans : undefined,
          };
        }
        // Keep the bounded re-decode dependency range editable around forced cuts.
        const editableBoundary =
          this.inference.timedSpeechSpans && !work.final
            ? Math.max(cursor.proofreadFrames, selected.endFrame - 8 * 16000)
            : selected.endFrame;
        const partition = reconciled.spans
          ? partitionSpeechWindow(reconciled, editableBoundary)
          : {
              committedFrame: selected.endFrame,
              committedText: reconciled.text,
              pending: undefined,
            };
        const textState = await processLongRecordingTextWindow(
          copy(work.manifest.textState),
          partition.committedText,
          settings,
          this.inference,
          signal,
        );
        const spans = drainLongRecordingTextSpans(textState);
        await this.mutate(async () => {
          const manifest = copy(this.lookup(id));
          if (manifest.snapshot.captureState === "discarded") return;
          const record: WindowRecord = {
            runID: work.runID,
            firstFrame: work.firstFrame,
            frameCount: selected.endFrame - selected.startFrame,
            speech,
            spans,
          };
          await atomicPrivateWrite(
            join(this.directory(id), "windows", `${manifest.nextWindow}.json`),
            JSON.stringify(record),
          );
          manifest.nextWindow++;
          manifest.textState = textState;
          const updatedCursor = manifest.cursors.find((cursor) => cursor.runID === work.runID)!;
          updatedCursor.frameCount = selected.nextStartFrame;
          updatedCursor.transcribedFrames = selected.endFrame;
          updatedCursor.proofreadFrames = partition.committedFrame;
          updatedCursor.pending = partition.pending;
          manifest.snapshot.transcribedFrames = manifest.cursors.reduce(
            (sum, cursor) => sum + cursor.transcribedFrames,
            0,
          );
          manifest.snapshot.proofreadFrames = manifest.cursors.reduce(
            (sum, cursor) => sum + cursor.proofreadFrames,
            0,
          );
          manifest.snapshot.previewText = speech.text.slice(-4096);
          manifest.snapshot.processingState = "queued";
          await this.commit(manifest);
        });
      }
      return true;
    } catch (error) {
      if (this.stopping) return false;
      await this.mutate(async () => {
        const manifest = copy(this.lookup(id));
        if (manifest.snapshot.captureState === "discarded") return;
        manifest.snapshot.processingState = "failed";
        manifest.snapshot.error =
          error instanceof Error
            ? error.message
            : "Speech processing failed. Audio has been preserved.";
        await this.commit(manifest);
      });
      return false;
    } finally {
      if (this.jobs.get(id) === job) this.jobs.delete(id);
      if (job.signal.aborted) await rm(join(this.directory(id), "window.wav"), { force: true });
    }
  }
  private async assembleText(manifest: Manifest) {
    const spans: TextSpan[] = [];
    let speech: SpeechInferenceResult | undefined;
    let speechSeconds = 0;
    for (let index = 0; index < manifest.nextWindow; index++) {
      const window = JSON.parse(
        (
          await readRegularFile(
            join(this.directory(manifest.snapshot.id), "windows", `${index}.json`),
            MAX_MANIFEST_BYTES,
          )
        ).toString(),
      ) as { spans: TextSpan[]; speech?: SpeechInferenceResult };
      spans.push(...window.spans);
      if (window.speech) {
        speech = window.speech;
        speechSeconds += speech.processingSeconds;
      }
    }
    return { ...longRecordingTextResult(manifest.textState, spans), speech, speechSeconds };
  }
  private audioMetadata(snapshot: RecordingSnapshot, kind: AudioKind): AudioArtifact | undefined {
    const streams = snapshot.streams.filter((stream) => stream.kind === kind);
    const format = streams[0]?.format;
    if (
      !format ||
      streams.some(
        (stream) =>
          stream.format.sampleRate !== format.sampleRate ||
          stream.format.channels !== format.channels,
      )
    )
      return undefined;
    const frameCount = streams.reduce((sum, stream) => sum + stream.frameCount, 0);
    const byteCount = frameCount * format.channels * 4 + 44;
    if (byteCount > 0xffffffff) return undefined;
    return { filename: `${kind}.wav`, ...format, frameCount, byteCount, encoding: "pcm_f32le" };
  }
  private async readAudioRange(
    id: string,
    runID: string,
    kind: AudioKind,
    firstFrame: number,
    frameCount: number,
  ) {
    const stream = this.lookup(id).snapshot.streams.find(
      (stream) => stream.runID === runID && stream.kind === kind,
    );
    if (!stream || firstFrame + frameCount > stream.frameCount)
      throw failure("missing_audio", "The requested audio is not yet durable.");
    await requireRegularDirectory(this.directory(id));
    await requireRegularDirectory(join(this.directory(id), runID));
    await requireRegularDirectory(this.chunkDirectory(id, runID, kind));
    const bytesPerFrame = stream.format.channels * 4;
    const output = Buffer.alloc(frameCount * bytesPerFrame);
    const positions = this.chunks.get(this.streamKey(id, runID, kind)) ?? [];
    let low = 0,
      high = positions.length;
    while (low < high) {
      const mid = Math.floor((low + high) / 2);
      const position = positions[mid]!;
      if (position.firstFrame + position.frameCount <= firstFrame) low = mid + 1;
      else high = mid;
    }
    let written = 0;
    for (let index = low; index < positions.length && written < output.length; index++) {
      const position = positions[index]!;
      const bytes = await readRegularFile(
        this.chunkPath(id, runID, kind, position.sequence, "pcm"),
        MAX_CHUNK_BYTES,
      );
      const receipt = JSON.parse(
        (
          await readRegularFile(this.chunkPath(id, runID, kind, position.sequence, "json"), 4096)
        ).toString(),
      ) as Receipt;
      if (sha256(bytes) !== receipt.sha256)
        throw failure("damaged_audio", "Durable audio checksum verification failed.", 500);
      const offset = Math.max(0, firstFrame - position.firstFrame) * bytesPerFrame;
      const count = Math.min(bytes.length - offset, output.length - written);
      bytes.copy(output, written, offset, offset + count);
      written += count;
    }
    if (written !== output.length)
      throw failure("missing_audio", "Audio contains an unacknowledged gap.", 500);
    return output;
  }
  private wavHeader(bytes: number, format: AudioStreamFormat) {
    if (bytes > 0xffffffff - 36)
      throw failure(
        "export_too_large",
        "This recording exceeds the RIFF WAV export limit; its original chunks remain preserved.",
        413,
      );
    const header = Buffer.alloc(44);
    header.write("RIFF");
    header.writeUInt32LE(bytes + 36, 4);
    header.write("WAVEfmt ", 8);
    header.writeUInt32LE(16, 16);
    header.writeUInt16LE(3, 20);
    header.writeUInt16LE(format.channels, 22);
    header.writeUInt32LE(format.sampleRate, 24);
    header.writeUInt32LE(format.sampleRate * format.channels * 4, 28);
    header.writeUInt16LE(format.channels * 4, 32);
    header.writeUInt16LE(32, 34);
    header.write("data", 36);
    header.writeUInt32LE(bytes, 40);
    return header;
  }
  async detail(id: string) {
    const snapshot = await this.get(id);
    const result =
      snapshot.processingState === "completed"
        ? (JSON.parse(
            (
              await readRegularFile(
                join(this.directory(snapshot.id), "result.json"),
                64 * 1024 * 1024,
              )
            ).toString(),
          ) as GenerationRecord)
        : undefined;
    return { snapshot, result };
  }
  history(limit: number, before?: string): Promise<RecordingPage> {
    return this.mutate(() => {
      if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100)
        throw failure("invalid_limit", "Choose a history page size from 1 to 100.", 400);
      const records = [...this.sessions.values()]
        .map(({ snapshot }) => snapshot)
        .filter((snapshot) => snapshot.captureState !== "discarded")
        .sort(
          (a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt) || b.id.localeCompare(a.id),
        );
      const cursor = before
        ? records.findIndex((snapshot) => snapshot.id === before.toUpperCase())
        : -1;
      if (before && cursor < 0) throw failure("invalid_cursor", "Reload recording history.", 400);
      const start = cursor + 1,
        items = records.slice(start, start + limit);
      return {
        items: copy(items),
        nextCursor: start + items.length < records.length ? items.at(-1)?.id : undefined,
      };
    });
  }
  async transcript(id: string) {
    const snapshot = await this.get(id);
    if (snapshot.processingState !== "completed")
      throw failure("transcript_pending", "The transcript is not complete.");
    return (
      await readRegularFile(join(this.directory(snapshot.id), "transcript.txt"), 64 * 1024 * 1024)
    ).toString();
  }
  async artifact(id: string, kind: string, runID?: string) {
    const snapshot = await this.get(id);
    id = snapshot.id;
    if (snapshot.captureState === "discarded")
      throw failure("artifact_not_found", "Recording discarded.", 404);
    if (kind === "transcript" || kind === "transcript.txt") {
      await this.transcript(id);
      return open(
        join(this.directory(id), "transcript.txt"),
        constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
      );
    }
    const audioKind =
      kind === "inference" || kind === "inference.wav"
        ? "inference"
        : kind === "original" || kind === "original.wav"
          ? "original"
          : undefined;
    if (!audioKind) throw failure("artifact_not_found", "Artifact not found.", 404);
    if (snapshot.processingState !== "completed")
      throw failure("artifact_pending", "Stop and finish processing before exporting audio.");
    if (runID && !isUUID(runID)) throw failure("invalid_run", "Capture run must be a UUID.", 400);
    const streams = snapshot.streams.filter(
      (stream) =>
        stream.kind === audioKind && (!runID || stream.runID.toUpperCase() === runID.toUpperCase()),
    );
    if (!streams.length) throw failure("artifact_not_found", "Audio artifact not found.", 404);
    const format = streams[0]!.format;
    if (streams.some((stream) => JSON.stringify(stream.format) !== JSON.stringify(format)))
      throw failure(
        "mixed_audio_formats",
        "Original capture runs have different formats; export each preserved run separately.",
        409,
      );
    const totalBytes = streams.reduce(
      (sum, stream) => sum + stream.frameCount * format.channels * 4,
      0,
    );
    const header = this.wavHeader(totalBytes, format);
    await requireDiskSpace(this.configuration.dataDirectory);
    const disk = await statfs(this.configuration.dataDirectory, { bigint: true });
    if (disk.bavail * disk.bsize < BigInt(totalBytes) + 100n * 1024n * 1024n)
      throw failure(
        "storage_full",
        "More free disk space is required for this on-demand audio export.",
        507,
      );
    const path = join(this.directory(id), `${audioKind}-${uuid()}.wav`);
    const output = await open(
      path,
      constants.O_RDWR | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
      0o600,
    );
    try {
      // The export is disposable. Unlink before writing so a process crash
      // cannot strand a multi-gigabyte derivative of the canonical chunks.
      await rm(path);
      await output.writeFile(header);
      for (const stream of streams) {
        await requireRegularDirectory(join(this.directory(id), stream.runID));
        await requireRegularDirectory(this.chunkDirectory(id, stream.runID, audioKind));
        for (const position of this.chunks.get(this.streamKey(id, stream.runID, audioKind)) ?? []) {
          const bytes = await readRegularFile(
            this.chunkPath(id, stream.runID, audioKind, position.sequence, "pcm"),
            MAX_CHUNK_BYTES,
          );
          await output.writeFile(bytes);
        }
      }
      await output.sync();
      return output;
    } catch (error) {
      await output.close();
      await rm(path, { force: true });
      throw error;
    }
  }
  recordDelivery(id: string, receipt: DeliveryReceipt) {
    return this.mutate(async () => {
      this.assertRunning();
      const manifest = this.lookup(id);
      if (manifest.snapshot.processingState !== "completed")
        throw failure("invalid_delivery", "Delivery requires a finalized transcript.", 400);
      if (
        ![
          "inserted",
          "copied",
          "unconfirmed",
          "failed",
          "tested",
          "listUpdated",
          "cancelled",
          "none",
        ].includes(receipt.status) ||
        Buffer.byteLength(receipt.message ?? "") > 4096
      )
        throw failure("invalid_delivery", "Invalid delivery receipt.", 400);
      const result = JSON.parse(
        (
          await readRegularFile(
            join(this.directory(manifest.snapshot.id), "result.json"),
            64 * 1024 * 1024,
          )
        ).toString(),
      ) as GenerationRecord;
      if (result.delivery) {
        if (
          result.delivery.status !== receipt.status ||
          result.delivery.message !== receipt.message
        )
          throw failure("delivery_recorded", "This recording already has a delivery outcome.");
        return result;
      }
      result.delivery = { status: receipt.status, message: receipt.message, reportedAt: date() };
      result.updatedAt = date();
      await atomicPrivateWrite(
        join(this.directory(manifest.snapshot.id), "result.json"),
        JSON.stringify(result),
      );
      return result;
    });
  }
  async shutdown() {
    this.stopping = true;
    this.controller.abort();
    await this.worker;
    await this.queue;
  }
}
