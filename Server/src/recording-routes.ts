import websocket from "@fastify/websocket";
import type { FastifyInstance } from "fastify";
import type { RawData, WebSocket } from "ws";
import { ServiceError } from "./errors.ts";
import {
  decodeRecordingAudioMessage,
  parseRecordingClientMessage,
  MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES,
  MAXIMUM_RECORDING_IN_FLIGHT_BYTES,
  MAXIMUM_RECORDING_MESSAGE_BYTES,
  MAXIMUM_RECORDING_PCM_BYTES,
  RECORDING_WS_PROTOCOL,
  type RecordingServerMessage,
  type RecordingSnapshot,
} from "./recording-contract.ts";
import type { RecordingService } from "./recording-service.ts";
import { validateBody } from "./validation.ts";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const identifier = (value: string) => {
  if (!uuidPattern.test(value))
    throw new ServiceError(400, "invalid_id", "A recording ID must be a UUID.");
  return value.toLowerCase();
};
const pageSize = (value: string | undefined) => {
  if (value === undefined) return 50;
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value)))
    throw new ServiceError(400, "invalid_limit", "Invalid history page size.");
  return Number(value);
};
const rawLength = (data: RawData) =>
  Array.isArray(data)
    ? data.reduce((length, part) => length + part.byteLength, 0)
    : data.byteLength;
const rawBuffer = (data: RawData) =>
  Array.isArray(data) ? Buffer.concat(data) : Buffer.isBuffer(data) ? data : Buffer.from(data);

const maximumQueuedMessages = 16;
const maximumOutboundBytes = MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES;
const maximumPayloadBytes = Math.max(
  MAXIMUM_RECORDING_MESSAGE_BYTES,
  MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES,
);
const heartbeatInterval = 30_000;
const progressInterval = 500;

function streamRecording(socket: WebSocket, id: string, service: RecordingService) {
  let epoch: number | undefined;
  let queuedBytes = 0;
  let queuedMessages = 0;
  let queue = Promise.resolve();
  let closed = false;
  let alive = true;
  let unsubscribe: (() => void) | undefined;
  let latestProgress: RecordingSnapshot | undefined;
  let progressTimer: ReturnType<typeof setTimeout> | undefined;

  const send = (message: RecordingServerMessage) => {
    if (closed || socket.readyState !== socket.OPEN) return;
    const payload = JSON.stringify(message);
    if (socket.bufferedAmount + Buffer.byteLength(payload) > maximumOutboundBytes) {
      socket.terminate();
      return;
    }
    socket.send(payload, (error) => {
      if (error) socket.terminate();
    });
  };
  const fail = (error: unknown) => {
    const failure =
      error instanceof ServiceError
        ? error
        : new ServiceError(500, "internal_error", "The server could not process this message.");
    send({
      type: "error",
      code: failure.code,
      message: failure.message,
      retryable: failure.status >= 500 || failure.status === 429,
    });
  };
  const progress = (snapshot: RecordingSnapshot) => {
    if (epoch !== undefined && snapshot.epoch !== epoch) {
      socket.close(1008, "Recording resumed on another connection.");
      return;
    }
    latestProgress = snapshot;
    if (progressTimer !== undefined) return;
    progressTimer = setTimeout(() => {
      progressTimer = undefined;
      if (latestProgress) send({ type: "progress", snapshot: latestProgress });
      latestProgress = undefined;
    }, progressInterval);
    progressTimer.unref();
  };
  const requireEpoch = (received: number) => {
    if (epoch === undefined)
      throw new ServiceError(409, "resume_required", "Resume the recording before uploading.");
    if (received !== epoch)
      throw new ServiceError(
        409,
        "stale_epoch",
        "Resume the recording to obtain its current epoch.",
      );
  };
  const handle = async (data: RawData, binary: boolean) => {
    if (closed) return;
    const buffer = rawBuffer(data);
    if (binary) {
      const decoded = decodeRecordingAudioMessage(buffer);
      if (!decoded.ok) {
        send({ type: "error", ...decoded.error });
        return;
      }
      requireEpoch(decoded.value.header.epoch);
      const pcm = decoded.value.pcm;
      const ack = await service.appendAudio(
        id,
        decoded.value.header,
        Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength),
      );
      send(ack);
      return;
    }
    if (buffer.length > MAXIMUM_RECORDING_CONTROL_MESSAGE_BYTES)
      throw new ServiceError(
        413,
        "message_too_large",
        "The control message exceeded its size limit.",
      );
    const parsed = parseRecordingClientMessage(buffer.toString("utf8"));
    if (!parsed.ok) {
      send({ type: "error", ...parsed.error });
      return;
    }
    if (parsed.value.type === "resume") {
      if (epoch !== undefined)
        throw new ServiceError(
          409,
          "already_resumed",
          "This connection already owns a recording epoch.",
        );
      const snapshot = await service.resume(id);
      epoch = snapshot.epoch;
      unsubscribe = service.subscribe(id, progress);
      if (closed) {
        unsubscribe();
        unsubscribe = undefined;
        return;
      }
      send({ type: "snapshot", snapshot });
    } else if (parsed.value.type === "stop") {
      requireEpoch(parsed.value.epoch);
      const snapshot = await service.stop(
        id,
        parsed.value.epoch,
        parsed.value.runs,
        parsed.value.runTimings,
      );
      send({ type: "snapshot", snapshot });
    } else if (parsed.value.type === "pause") {
      requireEpoch(parsed.value.epoch);
      const snapshot = await service.pause(
        id,
        parsed.value.epoch,
        parsed.value.runs,
        parsed.value.runTimings,
        parsed.value.interruption,
      );
      send({ type: "snapshot", snapshot });
    } else if (parsed.value.type === "context") {
      requireEpoch(parsed.value.epoch);
      const snapshot = await service.setContinuation(
        id,
        parsed.value.epoch,
        parsed.value.continuationID,
      );
      send({ type: "snapshot", snapshot });
    } else {
      send({ type: "snapshot", snapshot: await service.get(id) });
    }
  };
  socket.on("message", (data, binary) => {
    const length = rawLength(data);
    if (
      length > (binary ? MAXIMUM_RECORDING_MESSAGE_BYTES : maximumPayloadBytes) ||
      queuedBytes + length > MAXIMUM_RECORDING_IN_FLIGHT_BYTES ||
      queuedMessages >= maximumQueuedMessages
    ) {
      send({
        type: "error",
        code: "upload_backpressure",
        message: "Wait for acknowledged audio before sending more.",
        retryable: true,
      });
      socket.close(1009, "Receive queue exceeded.");
      return;
    }
    queuedBytes += length;
    queuedMessages += 1;
    queue = queue
      .then(() => handle(data, binary))
      .catch(fail)
      .finally(() => {
        queuedBytes -= length;
        queuedMessages -= 1;
      });
  });
  socket.on("pong", () => {
    alive = true;
  });
  const heartbeat = setInterval(() => {
    if (!alive) {
      socket.terminate();
      return;
    }
    alive = false;
    if (socket.readyState === socket.OPEN) socket.ping();
  }, heartbeatInterval);
  heartbeat.unref();
  socket.on("error", () => socket.terminate());
  socket.on("close", () => {
    closed = true;
    clearInterval(heartbeat);
    if (progressTimer !== undefined) clearTimeout(progressTimer);
    unsubscribe?.();
    // Wait for an in-progress durable append before marking the recoverable prefix interrupted.
    void queue
      .then(async () => {
        if (epoch !== undefined) await service.interrupt(id, epoch);
      })
      .catch(() => {});
  });
}

type IDParams = { id: string };
export function registerRecordingRoutes(app: FastifyInstance, service: RecordingService) {
  app.register(async (routes) => {
    await routes.register(websocket, {
      options: {
        maxPayload: maximumPayloadBytes,
        perMessageDeflate: false,
        handleProtocols: (protocols) =>
          protocols.has(RECORDING_WS_PROTOCOL) ? RECORDING_WS_PROTOCOL : false,
      },
    });
    routes.get("/v2/recordings/capabilities", () => ({
      protocol: RECORDING_WS_PROTOCOL,
      maximumPCMBytes: MAXIMUM_RECORDING_PCM_BYTES,
    }));
    routes.post("/v2/recordings", async (request, reply) =>
      reply
        .code(201)
        .send(await service.create(validateBody("CreateGenerationRequest", request.body))),
    );
    routes.get<{ Querystring: { limit?: string; before?: string } }>("/v2/recordings", (request) =>
      service.history(pageSize(request.query.limit), request.query.before),
    );
    routes.get<{ Params: IDParams }>("/v2/recordings/:id", (request) =>
      service.detail(identifier(request.params.id)),
    );
    routes.get<{ Params: IDParams }>("/v2/recordings/:id/transcript", async (request, reply) =>
      reply
        .type("text/plain; charset=utf-8")
        .send(await service.transcript(identifier(request.params.id))),
    );
    for (const path of [
      "/v2/recordings/:id/audio/:kind",
      "/v2/recordings/:id/audio/:kind/:runID",
    ]) {
      routes.get<{ Params: IDParams & { kind: string; runID?: string } }>(
        path,
        async (request, reply) => {
          const kind = request.params.kind;
          if (kind !== "inference" && kind !== "original")
            throw new ServiceError(
              400,
              "invalid_audio_kind",
              "Choose inference or original audio.",
            );
          const runID =
            request.params.runID === undefined ? undefined : identifier(request.params.runID);
          const file = await service.artifact(identifier(request.params.id), kind, runID);
          return reply.type("audio/wav").send(file.createReadStream({ autoClose: true, start: 0 }));
        },
      );
    }
    routes.post<{ Params: IDParams }>("/v2/recordings/:id/discard", (request) =>
      service.discard(identifier(request.params.id)),
    );
    routes.post<{ Params: IDParams }>("/v2/recordings/:id/delivery", (request) =>
      service.recordDelivery(
        identifier(request.params.id),
        validateBody("DeliveryReceipt", request.body),
      ),
    );
    routes.get<{ Params: IDParams }>(
      "/v2/recordings/:id/stream",
      {
        websocket: true,
        preValidation: async (request) => {
          identifier(request.params.id);
          const offered = request.headers["sec-websocket-protocol"]
            ?.split(",")
            .map((value) => value.trim());
          if (!offered?.includes(RECORDING_WS_PROTOCOL))
            throw new ServiceError(
              400,
              "protocol_required",
              "Use the sotto.recording.v1 WebSocket protocol.",
            );
          await service.get(identifier(request.params.id));
        },
      },
      (socket, request) => streamRecording(socket, identifier(request.params.id), service),
    );
  });
}
