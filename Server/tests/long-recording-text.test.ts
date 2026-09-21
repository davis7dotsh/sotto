import { describe, expect, test } from "bun:test";
import type { DictationContinuation, ServerPreferences, SpokenListContext } from "../src/api.ts";
import {
  createLongRecordingTextState,
  drainLongRecordingTextSpans,
  finalizeLongRecordingText,
  longRecordingTextResult,
  processLongRecordingTextWindow,
  type LongRecordingTextSpan,
} from "../src/domain/long-recording-text.ts";
import { InferenceError } from "../src/inference/native-inference.ts";
import { formatSpokenList } from "../src/domain/lists.ts";
import { composeDictation } from "../src/domain/composition.ts";
import { FakeInference } from "./support.ts";

const settings = (textCorrectionEnabled = false): ServerPreferences => ({
  language: "en",
  vocabulary: "",
  dictionary: {
    lists: [
      {
        id: "personal",
        name: "Personal",
        entries: [{ id: "codex", term: "Codex", aliases: ["code x"], isPriority: true }],
      },
    ],
  },
  proofreadingPrompt: "Clean punctuation and preserve dictated content.",
  textCorrectionEnabled,
  keepOriginalAudio: false,
});

class ProofFixture extends FakeInference {
  calls: string[] = [];
  rewrite = (text: string) => text;
  override async correct(text: string) {
    this.calls.push(text);
    return { text: this.rewrite(text), processingSeconds: 0.01, engineVersion: "fixture" };
  }
}

async function assemble(
  windows: string[],
  preferences = settings(),
  inference = new ProofFixture(),
  initialListContext?: SpokenListContext,
) {
  let state = createLongRecordingTextState(initialListContext);
  const journal: LongRecordingTextSpan[] = [];
  for (const text of windows) {
    state = await processLongRecordingTextWindow(state, text, preferences, inference);
    journal.push(...drainLongRecordingTextSpans(state));
    state = JSON.parse(JSON.stringify(state));
  }
  state = await finalizeLongRecordingText(state, preferences, inference);
  return {
    ...longRecordingTextResult(state, journal),
    spans: [...journal, ...state.spans],
    state,
    inference,
  };
}

describe("incremental long-recording text", () => {
  test("assembled metadata preserves destination continuation across checkpoints", async () => {
    const previous: DictationContinuation = {
      list: { style: "numbered", nextNumber: 4 },
      preview: "3. Previous point",
      boundary: "line",
    };
    const result = await assemble(
      ["Next item, " + "Keep this sentence. ".repeat(100), "Next item, final point."],
      settings(),
      new ProofFixture(),
      previous.list,
    );
    expect(result.spans.length).toBeGreaterThan(1);
    expect(result.formatted.continuesPreviousList).toBe(true);
    expect(result.formatted.containsList).toBe(true);
    expect(result.formatted.endsWithList).toBe(true);
    expect(result.formatted.context?.nextNumber).toBe(6);
    const composition = composeDictation(result.formatted, previous);
    expect(composition.insertion).toBe("\n" + result.cleanedText);
    expect(composition.preview).toBe(previous.preview + "\n" + result.cleanedText);
    expect(composition.continuation?.list?.nextNumber).toBe(6);

    const replacement = await assemble(
      [
        "Start a new numbered list. Next item, " + "Keep this sentence. ".repeat(100),
        "Next item, new point.",
      ],
      settings(),
      new ProofFixture(),
      previous.list,
    );
    expect(replacement.formatted.continuesPreviousList).toBe(false);
    expect(composeDictation(replacement.formatted, previous).insertion).toBe(
      "\n\n" + replacement.cleanedText,
    );
    expect(composeDictation(replacement.formatted, previous).preview).toBe(replacement.cleanedText);

    const end = await assemble(["End the", "list."], settings(), new ProofFixture(), previous.list);
    expect(end.formatted.isControlOnly).toBe(true);
    expect(end.formatted.endedList).toBe(true);
    expect(end.formatted.endsWithList).toBe(false);
    expect(composeDictation(end.formatted, previous).continuation).toEqual({
      preview: previous.preview,
      boundary: "paragraph",
    });
    expect(end.spans[0]?.listControls?.sourceText).toBe("End the list.");
  });

  test("a forced cut after an item marker preserves the next item's number", async () => {
    for (const count of [1_187, 1_189, 1_190]) {
      const prefix = "Next item, " + "a ".repeat(count) + "a, Next item, ";
      const result = await assemble(["Start a list. " + prefix + "final detail ".repeat(100)]);
      expect(result.cleanedText.match(/^\d+\./gm)).toEqual(["1.", "2."]);
      expect(result.cleanedText).toContain("\n2. final detail");
    }
    const marker = formatSpokenList(
      "Next item,",
      { style: "numbered", nextNumber: 2 },
      { continuePreviousItem: true },
    );
    expect(marker.endsWithOpenItem).toBe(false);
    expect(marker.context?.nextNumber).toBe(2);
  });

  test("ASR cuts preserve multiword dictionary aliases and list controls", async () => {
    for (const windows of [
      [
        "Start a numbered",
        "list. Next item, use code",
        "x. Next",
        "item, do not merge. End the",
        "list. Finished.",
      ],
      [
        "Start a numbered list. Next item, use",
        "code x. Next item, do",
        "not merge. End the list.",
        "Finished.",
      ],
    ]) {
      const result = await assemble(windows);
      expect(result.cleanedText).toBe("1. use Codex\n2. do not merge\n\nFinished.");
      expect(result.listContext).toBeUndefined();
    }
  });

  test("an item longer than the model window retains one list marker", async () => {
    const words = Array.from({ length: 1_100 }, (_, index) => `detail${index}`).join(" ");
    const result = await assemble([
      "Start a numbered list. Next item, " + words.slice(0, 4_000),
      words.slice(4_000) + ". Next item, final point. End the list.",
    ]);
    expect(result.cleanedText.match(/^\d+\./gm)).toEqual(["1.", "2."]);
    expect(result.cleanedText).toContain("2. final point");
    expect(result.cleanedText.replace(/^1\. /u, "").split("\n2.")[0]).toBe(words);
    expect(result.spans.length).toBeGreaterThan(3);
    expect(result.spans.map((span) => span.rawText).join("")).toBe(result.rawText);
  });

  test("sentences within a streamed list item retain punctuation", async () => {
    const first = "Start a list. Next item, " + "We keep this sentence. ".repeat(90);
    const result = await assemble([first, "Still the same item. Next item, done."]);
    expect(result.cleanedText.match(/^\d+\./gm)).toEqual(["1.", "2."]);
    expect(result.cleanedText).toContain("sentence. We keep");
    expect(result.cleanedText).toContain("sentence. Still the same item");
  });

  test("nearby spoken repairs crossing ASR windows are evaluated together", async () => {
    const inference = new ProofFixture();
    inference.rewrite = (text) =>
      text
        .replace("Make it 42, sorry, 24", "Make it 24")
        .replace("Do merge, correction, do not merge", "Do not merge");
    const prefix = "This sentence is retained. ".repeat(130);
    const result = await assemble(
      [
        prefix + "Make it 42,",
        "sorry, 24. Do merge, correction,",
        "do not merge. " + "More information follows. ".repeat(50),
      ],
      settings(true),
      inference,
    );
    expect(result.cleanedText).toContain("Make it 24.");
    expect(result.cleanedText).toContain("Do not merge.");
    expect(result.cleanedText).not.toContain("Make it 42");
    expect(
      result.spans
        .flatMap((span) => span.processing)
        .some((record) => (record.verifiedRepairs?.length ?? 0) > 0),
    ).toBe(true);
  });

  test("a long transcript applies dictionary rules beyond 24 KiB with bounded checkpoints", async () => {
    let state = createLongRecordingTextState();
    const journal: LongRecordingTextSpan[] = [];
    const preferences = settings();
    const inference = new ProofFixture();
    const window = "We use code x for this dictation. ".repeat(50);
    for (let index = 0; index < 40; index++) {
      state = await processLongRecordingTextWindow(state, window, preferences, inference);
      journal.push(...drainLongRecordingTextSpans(state));
      expect(state.pendingText.length).toBeLessThan(3_200);
      expect(JSON.stringify(state).length).toBeLessThan(3_600);
    }
    state = await finalizeLongRecordingText(state, preferences, inference);
    const result = longRecordingTextResult(state, journal);
    expect(Buffer.byteLength(result.cleanedText)).toBeGreaterThan(24 * 1024);
    expect(result.cleanedText.match(/Codex/gu)).toHaveLength(2_000);
    expect(result.cleanedText).not.toContain("code x");
    expect(inference.calls).toHaveLength(0);
  });

  test("native tokenizer budget rejection splits bounded requests", async () => {
    const inference = new ProofFixture();
    inference.rewrite = (text) => {
      if (text.length > 350)
        throw new InferenceError(
          "invalidRequest",
          "The transcript exceeds the correction context token budget.",
        );
      return text;
    };
    const source = "Preserve all dictated words and numbers 24. ".repeat(80);
    const result = await assemble([source], settings(true), inference);
    expect(result.cleanedText).toBe(source.trim());
    expect(Math.max(...inference.calls.map((text) => text.length))).toBeLessThanOrEqual(2_400);
    expect(
      result.spans
        .flatMap((span) => span.processing)
        .every((record) => record.status === "unchanged"),
    ).toBe(true);
  });

  test("rejected rewrites and timeouts retain deterministic text", async () => {
    const bad = new ProofFixture();
    bad.rewrite = (text) => text.replace("do not merge", "do merge");
    const rejected = await assemble(["We use code", "x and do not merge."], settings(true), bad);
    expect(rejected.cleanedText).toBe("We use Codex and do not merge.");
    expect(rejected.spans[0]?.processing[0]?.status).toBe("rejected");
    const timeout = new ProofFixture();
    timeout.rewrite = () => {
      throw new InferenceError("timeout", "Local correction exceeded its time limit.");
    };
    const failed = await assemble(["We use code x and do not merge."], settings(true), timeout);
    expect(failed.cleanedText).toBe("We use Codex and do not merge.");
    expect(timeout.calls).toHaveLength(1);
    expect(failed.spans[0]?.processing[0]?.status).toBe("failed");
  });

  test("finalization is idempotent and aborted work leaves its checkpoint intact", async () => {
    const initial = createLongRecordingTextState();
    const inference = new ProofFixture();
    const controller = new AbortController();
    controller.abort();
    await expect(
      processLongRecordingTextWindow(
        initial,
        "A sentence. ".repeat(400),
        settings(true),
        inference,
        controller.signal,
      ),
    ).rejects.toThrow();
    expect(initial.pendingText).toBe("");
    const state = await processLongRecordingTextWindow(
      initial,
      "Pending text.",
      settings(),
      inference,
    );
    const finalized = await finalizeLongRecordingText(state, settings(), inference);
    expect(await finalizeLongRecordingText(finalized, settings(), inference)).toEqual(finalized);
    await expect(
      processLongRecordingTextWindow(finalized, "late", settings(), inference),
    ).rejects.toThrow("already finalized");
  });
});
