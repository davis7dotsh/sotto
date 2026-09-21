import { expect, test } from "bun:test";
import { FakeInference } from "./support.ts";
import { InferenceScheduler } from "../src/inference/serialized-inference.ts";

test("model scopes preserve optional boundary capability and its backend receiver", async () => {
  const ordinary = new InferenceScheduler(new FakeInference());
  expect(ordinary.scope().findSpeechBoundary).toBeUndefined();
  await ordinary.shutdown();
  class BoundaryBackend extends FakeInference {
    marker = "boundary backend";
    async findSpeechBoundary(_path: string, signal?: AbortSignal) {
      expect(this.marker).toBe("boundary backend");
      signal?.throwIfAborted();
      return 32.5;
    }
  }
  const capable = new InferenceScheduler(new BoundaryBackend());
  const scope = capable.scope();
  expect(await scope.findSpeechBoundary?.("window.wav")).toBe(32.5);
  await capable.shutdown();
});

test("legacy and session callers share a bounded model queue", async () => {
  const started: string[] = [];
  let release: (() => void) | undefined;
  class Backend extends FakeInference {
    override async correct(text: string) {
      started.push(text);
      if (text === "first") await new Promise<void>((resolve) => (release = resolve));
      return super.correct(text);
    }
  }
  const scheduler = new InferenceScheduler(new Backend());
  const legacy = scheduler.scope();
  const recording = scheduler.scope();
  const first = legacy.correct("first", [], "en", "prompt");
  const second = recording.correct("second", [], "en", "prompt");
  await Promise.resolve();
  expect(started).toEqual(["first"]);
  release?.();
  await Promise.all([first, second]);
  expect(started).toEqual(["first", "second"]);
  await scheduler.shutdown();
});

test("cancelling a queued caller cannot cancel another recording", async () => {
  let release: (() => void) | undefined;
  const started: string[] = [];
  class Backend extends FakeInference {
    override async correct(text: string) {
      started.push(text);
      if (text === "active") await new Promise<void>((resolve) => (release = resolve));
      return super.correct(text);
    }
    override async cancel() {
      throw new Error("Cancelling the shared backend would kill another caller.");
    }
  }
  const scheduler = new InferenceScheduler(new Backend());
  const active = scheduler.scope();
  const waiting = scheduler.scope();
  const first = active.correct("active", [], "en", "prompt");
  const cancelled = waiting
    .correct("cancelled", [], "en", "prompt")
    .catch((error: unknown) => error);
  await Promise.resolve();
  await waiting.cancel();
  release?.();
  await first;
  expect(await cancelled).toMatchObject({ message: "Inference was cancelled." });
  expect(started).toEqual(["active"]);
  expect((await waiting.correct("new", [], "en", "prompt")).text).toBe("new");
  await scheduler.shutdown();
});
