import { describe, expect, test } from "bun:test";
import {
  absoluteSpeechSpans,
  partitionSpeechWindow,
  resolveSpeechBoundaryWithRedecode,
  reconcileSpeechBoundary,
  selectSpeechWindow,
  speechSampleRate,
  type TimedSpeechWindow,
} from "../src/inference/speech-windows";
import { validSpeechSpans } from "../src/inference/native-inference";

const frame = (seconds: number) => Math.round(seconds * speechSampleRate);
function window(start: number, end: number, pieces: [string, number, number][]): TimedSpeechWindow {
  const spans = pieces.map(([text, startSeconds, endSeconds]) => ({
    text,
    startSeconds,
    endSeconds,
  }));
  return {
    startFrame: frame(start),
    endFrame: frame(end),
    spans,
    text: spans
      .map((span) => span.text)
      .join("")
      .trim(),
  };
}

describe("bounded speech-window selection", () => {
  test("continuous speech advances with bounded overlap only on timing-capable backends", () => {
    const samples = new Float32Array(frame(60)).fill(0.01);
    expect(
      selectSpeechWindow({ samples, startFrame: frame(120), final: false, timedSpans: true }),
    ).toMatchObject({
      startFrame: frame(120),
      endFrame: frame(165),
      nextStartFrame: frame(163),
      overlapFrames: frame(2),
      quietBoundary: false,
    });
    expect(selectSpeechWindow({ samples, startFrame: 0, final: false })).toMatchObject({
      endFrame: frame(45),
      nextStartFrame: frame(45),
      overlapFrames: 0,
    });
  });

  test("a conservative sustained silence yields a nonoverlapping boundary", () => {
    const samples = new Float32Array(frame(45)).fill(0.01);
    samples.fill(0, frame(40), frame(41));
    const selected = selectSpeechWindow({
      samples,
      startFrame: 0,
      final: false,
      timedSpans: true,
    })!;
    expect(selected.endFrame).toBe(frame(40.5));
    expect(selected.nextStartFrame).toBe(selected.endFrame);
    expect(selected.quietBoundary).toBe(true);
    samples.fill(0.0015, frame(40), frame(41));
    expect(
      selectSpeechWindow({ samples, startFrame: 0, final: false, timedSpans: true })!.quietBoundary,
    ).toBe(false);
  });

  test("finalization processes the exact tail and empty/unfinished buffers wait", () => {
    const samples = new Float32Array(frame(12));
    expect(selectSpeechWindow({ samples, startFrame: frame(43), final: false })).toBeUndefined();
    expect(
      selectSpeechWindow({ samples, startFrame: frame(43), final: true, timedSpans: true }),
    ).toMatchObject({
      endFrame: frame(55),
      nextStartFrame: frame(55),
      overlapFrames: 0,
    });
    expect(
      selectSpeechWindow({ samples: new Float32Array(), startFrame: 0, final: true }),
    ).toBeUndefined();
    samples[0] = Number.NaN;
    expect(() => selectSpeechWindow({ samples, startFrame: 0, final: true })).toThrow(
      "invalid audio",
    );
  });
});

describe("speech overlap reconciliation", () => {
  test("whole decoder segments retain an unfinished utterance across a quiet touching cut", () => {
    const first = window(0, 45, [
      ["Earlier.", 0, 1],
      [" Make", 38, 39],
      [" it", 39, 40],
      [" 42,", 40, 41],
      [" sorry,", 41, 43],
      [" 24.", 43, 45],
    ]);
    first.segmentSpans = [
      { text: "Earlier.", startSeconds: 0, endSeconds: 1 },
      { text: " Make it 42, sorry, 24.", startSeconds: 38, endSeconds: 45 },
    ];
    const checkpoint = partitionSpeechWindow(first, frame(43));
    expect(checkpoint.committedFrame).toBe(frame(38));
    expect(checkpoint.committedText).toBe("Earlier.");
    expect(checkpoint.pending!.text).toBe("Make it 42, sorry, 24.");
    const current = window(45, 90, [["Another utterance.", 45, 46]]);
    expect(reconcileSpeechBoundary({ previous: checkpoint.pending!, current })).toEqual({
      kind: "redecode",
      startFrame: frame(38),
      endFrame: frame(90),
    });
  });
  test("one fresh joined decode replaces an ambiguous entire provisional tail after partitioning", () => {
    const first = window(0, 45, [
      ["Fixed earlier.", 0, 1],
      [" Do", 38, 39],
      [" merge.", 44, 45],
    ]);
    const checkpoint = partitionSpeechWindow(first, frame(37));
    const previous = checkpoint.pending!;
    const current = window(43, 88, [
      [" do", 43.1, 43.5],
      [" not", 43.5, 44],
      [" merge.", 44, 44.8],
      [" Again", 87, 87.4],
      [" again.", 87.4, 88],
    ]);
    expect(reconcileSpeechBoundary({ previous, current })).toEqual({
      kind: "redecode",
      startFrame: frame(37),
      endFrame: frame(88),
    });
    const redecoded = window(37, 88, [
      ["Do", 38, 39],
      [" not", 39, 40],
      [" merge.", 40, 41],
      [" Again", 87, 87.4],
      [" again.", 87.4, 88],
    ]);
    const resolved = resolveSpeechBoundaryWithRedecode({ previous, current, redecoded });
    expect(resolved.kind).toBe("resolved");
    if (resolved.kind === "resolved") {
      expect(resolved.text).toBe("Do not merge. Again again.");
      expect(resolved.spans).toEqual(redecoded.spans);
    }
    expect(checkpoint.committedText).toBe("Fixed earlier.");
  });

  test("joined recovery cannot expand beyond its bounded source budget", () => {
    const previous = window(0, 90, [
      ["Earlier", 88, 89],
      [" words", 89, 90],
    ]);
    const current = window(88, 133, [
      ["different", 88, 89],
      [" words", 89, 90],
    ]);
    expect(reconcileSpeechBoundary({ previous, current }).kind).toBe("unresolved");
  });
  test("checkpointing retains crossing token groups and only commits covered pieces", () => {
    const joined = window(0, 88, [
      ["Earlier.", 0, 1],
      [" Long", 42.8, 43.2],
      [" word", 43.1, 43.5],
      [" later.", 44, 45],
    ]);
    const result = partitionSpeechWindow(joined, frame(43));
    expect(result.committedText).toBe("Earlier.");
    expect(result.committedFrame).toBe(frame(42.8));
    expect(result.pending!.text).toBe("Long word later.");
    expect(result.pending!.startFrame).toBe(frame(42.8));
  });

  test("bounded joined decoding must match the requested interval and can remain unresolved", () => {
    const previous = window(0, 45, [
      ["Do", 42, 42.5],
      [" merge.", 43, 44],
    ]);
    const current = window(43, 88, [
      [" do", 43.1, 43.5],
      [" not", 43.5, 44],
      [" merge.", 44, 44.8],
    ]);
    expect(
      resolveSpeechBoundaryWithRedecode({ previous, current, redecoded: window(38, 51, []) }).kind,
    ).toBe("unresolved");
    expect(
      resolveSpeechBoundaryWithRedecode({ previous, current, redecoded: window(37, 51, []) }).kind,
    ).toBe("unresolved");
  });
  test("timing reconciles duplicated overlap while retaining intentional repetition", () => {
    const previous = window(0, 45, [
      ["Say", 42, 42.7],
      [" that", 43, 43.7],
      [" again", 44, 44.7],
    ]);
    const current = window(43, 88, [
      [" that", 43.05, 43.75],
      [" again", 44.05, 44.75],
      [" again", 45, 45.7],
      [" please.", 46, 46.7],
    ]);
    const result = reconcileSpeechBoundary({ previous, current });
    expect(result.kind).toBe("resolved");
    if (result.kind === "resolved") expect(result.text).toBe("Say that again again please.");
  });

  test("nonoverlapping untimed results retain every repeated phrase", () => {
    const result = reconcileSpeechBoundary({
      previous: { startFrame: 0, endFrame: frame(45), text: "Again again." },
      current: { startFrame: frame(45), endFrame: frame(90), text: "Again again." },
    });
    expect(result).toEqual({
      kind: "resolved",
      spans: undefined,
      text: "Again again. Again again.",
    });
  });

  test("an acoustic disagreement requests one bounded joined decode then remains incomplete", () => {
    const previous = window(0, 45, [
      ["Do", 42, 42.5],
      [" merge.", 43, 44],
    ]);
    const current = window(43, 88, [
      [" do", 43.1, 43.5],
      [" not", 43.5, 44],
      [" merge.", 44, 44.8],
    ]);
    expect(reconcileSpeechBoundary({ previous, current })).toEqual({
      kind: "redecode",
      startFrame: frame(0),
      endFrame: frame(88),
    });
    expect(reconcileSpeechBoundary({ previous, current, resolutionAttempts: 1 }).kind).toBe(
      "unresolved",
    );
  });

  test("silence is legitimate covered audio but missing intervals never complete", () => {
    expect(
      reconcileSpeechBoundary({ previous: window(0, 45, []), current: window(43, 88, []) }),
    ).toEqual({ kind: "resolved", spans: [], text: "" });
    expect(
      reconcileSpeechBoundary({ previous: window(0, 45, []), current: window(46, 90, []) }).kind,
    ).toBe("unresolved");
  });

  test("malformed span coverage cannot be reconciled", () => {
    const previous = window(0, 45, [["Good.", 0, 1]]);
    const current = window(43, 88, [["Bad.", 42, 44]]);
    expect(reconcileSpeechBoundary({ previous, current }).kind).toBe("unresolved");
    expect(
      reconcileSpeechBoundary({
        previous,
        current: { startFrame: frame(43), endFrame: frame(88), text: "No timing." },
      }).kind,
    ).toBe("redecode");
  });
});

test("native evidence is finite, ordered, bounded, and covers every transcript byte", () => {
  expect(validSpeechSpans([], 2, "")).toBe(true);
  expect(validSpeechSpans(undefined, 2, "")).toBe(false);
  const spans = [
    { text: "Hello", startSeconds: 0, endSeconds: 1 },
    { text: " world.", startSeconds: 1, endSeconds: 2 },
  ];
  expect(validSpeechSpans(spans, 2, "Hello world.")).toBe(true);
  expect(validSpeechSpans(spans, 1, "Hello world.")).toBe(false);
  expect(validSpeechSpans(spans, 2, "Hello")).toBe(false);
  expect(validSpeechSpans([{ ...spans[0]!, startSeconds: Number.NaN }], 2, "Hello")).toBe(false);
  expect(
    absoluteSpeechSpans([{ text: "Hi", startSeconds: 0, endSeconds: 0.1 }], frame(43.123)),
  ).toEqual([{ text: "Hi", startSeconds: 43.123, endSeconds: 43.223 }]);
});
