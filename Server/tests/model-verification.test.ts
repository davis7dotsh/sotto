import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtemp, open, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelVerifier, type ModelPin } from "../src/inference/model-verification";

let directory: string;
let model: string;
let pin: ModelPin;

beforeAll(async () => {
  directory = await mkdtemp(join(tmpdir(), "v07-shared-model-verification-"));
  model = join(directory, "model.bin");
  // Real bounded reads exercise cancellation while hashing without mocking the
  // verifier or installing any production integrity bypass.
  const chunk = Buffer.alloc(4 * 1024 * 1024, 0x61);
  const digest = createHash("sha256");
  const handle = await open(model, "wx");
  try {
    for (let index = 0; index < 16; ++index) {
      await handle.writeFile(chunk);
      digest.update(chunk);
    }
  } finally {
    await handle.close();
  }
  pin = { bytes: chunk.length * 16, sha256: digest.digest("hex") };
});

afterAll(async () => {
  await rm(directory, { recursive: true, force: true });
});

describe("shared model-verification waiters", () => {
  test("cancelling one consumer leaves other consumers and later joiners intact", async () => {
    const verifier = new ModelVerifier();
    const firstController = new AbortController();
    const secondController = new AbortController();
    const first = verifier.verify(model, pin, firstController.signal).catch((error) => error);
    let secondSettled = false;
    const second = verifier.verify(model, pin, secondController.signal).then((result) => {
      secondSettled = true;
      return result;
    });
    // Both calls have joined before the file can finish its sixteen reads.
    await Bun.sleep(1);
    firstController.abort();
    expect(await first).toMatchObject({ code: "cancelled" });
    expect(secondSettled).toBe(false);
    const third = verifier.verify(model, pin);
    expect(await Promise.all([second, third])).toEqual([pin.sha256, pin.sha256]);
    expect(await verifier.isVerified(model, pin)).toBe(true);
    await verifier.shutdown();
  });

  test("each cancelled waiter exits while a remaining consumer succeeds", async () => {
    const verifier = new ModelVerifier();
    const firstController = new AbortController();
    const secondController = new AbortController();
    const first = verifier.verify(model, pin, firstController.signal).catch((error) => error);
    const second = verifier.verify(model, pin, secondController.signal).catch((error) => error);
    const remaining = verifier.verify(model, pin);
    await Bun.sleep(1);
    firstController.abort();
    secondController.abort();
    expect(await first).toMatchObject({ code: "cancelled" });
    expect(await second).toMatchObject({ code: "cancelled" });
    expect(await remaining).toBe(pin.sha256);
    expect(await verifier.isVerified(model, pin)).toBe(true);
    await verifier.shutdown();
  });

  test("aborting the final waiter permits immediate verification again", async () => {
    const verifier = new ModelVerifier();
    const controller = new AbortController();
    const cancelled = verifier.verify(model, pin, controller.signal).catch((error) => error);
    await Bun.sleep(1);
    controller.abort();
    expect(await cancelled).toMatchObject({ code: "cancelled" });
    expect(await verifier.verify(model, pin)).toBe(pin.sha256);
    expect(await verifier.isVerified(model, pin)).toBe(true);
    await verifier.shutdown();
  });

  test("explicit cancellation rejects every consumer without poisoning later work", async () => {
    const verifier = new ModelVerifier();
    const first = verifier.verify(model, pin).catch((error) => error);
    const second = verifier.verify(model, pin).catch((error) => error);
    await Bun.sleep(1);
    verifier.cancel();
    expect(await first).toMatchObject({ code: "cancelled" });
    expect(await second).toMatchObject({ code: "cancelled" });
    expect(await verifier.isVerified(model, pin)).toBe(false);
    expect(await verifier.verify(model, pin)).toBe(pin.sha256);
    await verifier.shutdown();
  });

  test("shutdown aborts all consumers and awaits cancelled hashes before reuse", async () => {
    const verifier = new ModelVerifier();
    const controller = new AbortController();
    const first = verifier.verify(model, pin, controller.signal).catch((error) => error);
    const second = verifier.verify(model, pin).catch((error) => error);
    await Bun.sleep(1);
    controller.abort();
    expect(await first).toMatchObject({ code: "cancelled" });
    await verifier.shutdown();
    expect(await second).toMatchObject({ code: "cancelled" });
    expect(await verifier.isVerified(model, pin)).toBe(false);
    expect(await verifier.verify(model, pin)).toBe(pin.sha256);
    await verifier.shutdown();
  });

  test("shutdown also cancels consumers still checking the digest cache", async () => {
    const verifier = new ModelVerifier();
    const first = verifier.verify(model, pin).catch((error) => error);
    const second = verifier.verify(model, pin).catch((error) => error);
    await verifier.shutdown();
    expect(await first).toMatchObject({ code: "cancelled" });
    expect(await second).toMatchObject({ code: "cancelled" });
    expect(await verifier.isVerified(model, pin)).toBe(false);
    expect(await verifier.verify(model, pin)).toBe(pin.sha256);
    await verifier.shutdown();
  });
});
