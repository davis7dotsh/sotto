import { acquireDataDirectoryLock } from "./data-lock.ts";
import { parseConfiguration, usage, type ServerConfiguration } from "./configuration.ts";
import { createHTTPServer } from "./http-server.ts";
import { GenerationService, defaultProofreadingPrompt } from "./generation-service.ts";
import { NativeInference, type InferenceBackend } from "./inference/native-inference.ts";
import { InferenceScheduler } from "./inference/serialized-inference.ts";
import { RecordingService } from "./recording-service.ts";
import { ServiceError } from "./errors.ts";

export async function startServer(configuration: ServerConfiguration, backend?: InferenceBackend) {
  const lock = acquireDataDirectoryLock(configuration.dataDirectory);
  const inference = new InferenceScheduler(backend ?? new NativeInference(configuration.inference));
  let service: GenerationService | undefined;
  let recordings: RecordingService | undefined;
  const stopServices = async () => {
    // Abort both owners before waiting: either can be queued behind the other.
    const stopped = await Promise.allSettled([recordings?.shutdown(), service?.shutdown()]);
    await inference.shutdown();
    for (const result of stopped) if (result.status === "rejected") throw result.reason;
  };
  try {
    service = await GenerationService.open(configuration, inference.scope());
    const legacy = service;
    recordings = await RecordingService.open(configuration, inference.scope(), {
      getPreferences: () => legacy.getPreferences(),
      resolveContinuation: (id, snapshot) => legacy.resolveRecordingContinuation(id, snapshot),
      admit: async () => {
        const health = await legacy.health();
        if (!health.ready)
          throw new ServiceError(
            503,
            "server_unavailable",
            health.message ?? "The server is not ready to start recording.",
          );
      },
    });
    const app = createHTTPServer(service, configuration.token, recordings);
    await service.start();
    const address = await app.listen({ host: configuration.host, port: configuration.port });
    let closing: Promise<void> | undefined;
    const close = () =>
      (closing ??= (async () => {
        try {
          await stopServices();
        } finally {
          try {
            await app.close();
          } finally {
            lock.release();
          }
        }
      })());
    return { app, service, recordings, address, close };
  } catch (error) {
    try {
      await stopServices();
    } finally {
      lock.release();
    }
    throw error;
  }
}

if (import.meta.main) {
  try {
    if (process.argv.includes("--help") || process.argv.includes("-h")) console.log(usage);
    else if (process.argv.includes("--print-default-proofreading-prompt"))
      console.log(defaultProofreadingPrompt);
    else {
      const server = await startServer(await parseConfiguration());
      console.log(`Sotto server listening at ${server.address}`);
      const stop = () => {
        void server.close().then(
          () => process.exit(0),
          () => process.exit(1),
        );
      };
      process.once("SIGTERM", stop);
      process.once("SIGINT", stop);
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : "The server could not start.");
    process.exitCode = 1;
  }
}
