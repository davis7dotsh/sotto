import type { SpeechSpan } from "./native-inference";

export const speechSampleRate = 16_000;
const windowFrames = 45 * speechSampleRate;
const minimumFrames = 30 * speechSampleRate;
const overlapFrames = 2 * speechSampleRate;
const analysisFrames = speechSampleRate / 50;
const quietFrames = speechSampleRate / 2;

/** A bounded buffer beginning at startFrame, never the whole recording. */
export function selectSpeechWindow(input: {
  samples: Float32Array;
  startFrame: number;
  final: boolean;
  timedSpans?: boolean;
}) {
  const { samples, startFrame, final, timedSpans = false } = input;
  if (!Number.isSafeInteger(startFrame) || startFrame < 0)
    throw new Error("The speech-window offset must be a nonnegative safe integer.");
  if (!samples.length || (!final && samples.length < windowFrames)) return;
  const available = Math.min(samples.length, windowFrames);
  for (let i = 0; i < available; ++i)
    if (!Number.isFinite(samples[i])) throw new Error("The speech window contains invalid audio.");
  let quietStart = -1;
  let cut = -1;
  for (let offset = minimumFrames; offset + analysisFrames <= available; offset += analysisFrames) {
    let square = 0;
    let peak = 0;
    for (let i = offset; i < offset + analysisFrames; ++i) {
      const sample = samples[i]!;
      square += sample * sample;
      peak = Math.max(peak, Math.abs(sample));
    }
    // Deliberately stricter than a speech detector: a quiet word ending must
    // not be mistaken for silence. Keep half a second of sustained near-zero.
    const quiet = peak < 0.002 && Math.sqrt(square / analysisFrames) < 0.0003;
    if (!quiet) {
      quietStart = -1;
    } else {
      if (quietStart === -1) quietStart = offset;
      if (offset + analysisFrames - quietStart >= quietFrames)
        cut = quietStart + Math.floor((offset + analysisFrames - quietStart) / 2);
    }
  }
  const finalTail = final && samples.length <= windowFrames;
  const end = finalTail ? available : cut === -1 ? available : cut;
  const overlap = !finalTail && cut === -1 && timedSpans ? overlapFrames : 0;
  return {
    startFrame,
    endFrame: startFrame + end,
    nextStartFrame: startFrame + end - overlap,
    overlapFrames: overlap,
    quietBoundary: !finalTail && cut !== -1,
  };
}

/** Apply the one bounded joined decode without expanding a provisional tail. */
export function resolveSpeechBoundaryWithRedecode(input: {
  previous: TimedSpeechWindow;
  current: TimedSpeechWindow;
  redecoded: TimedSpeechWindow;
}) {
  const requested = reconcileSpeechBoundary(input);
  if (requested.kind !== "redecode") return requested;
  if (
    input.redecoded.startFrame !== requested.startFrame ||
    input.redecoded.endFrame !== requested.endFrame
  )
    return {
      kind: "unresolved" as const,
      reason: "The joined decode does not cover the requested boundary interval.",
    };
  // Decode all provisional source coverage once. Splicing a short middle
  // decode introduces two more ambiguous seams when Whisper extrapolates a
  // truncated tail. Replace provisional evidence only; the earlier durable
  // text prefix is outside this exact source interval and remains unchanged.
  if (!input.redecoded.spans || !validWindow(input.redecoded))
    return {
      kind: "unresolved" as const,
      reason: "The replacement decode has invalid timed coverage.",
    };
  return assembled(input.redecoded.spans, input.redecoded.segmentSpans);
}

export interface TimedSpeechWindow {
  startFrame: number;
  endFrame: number;
  text: string;
  /** Absolute session seconds; preserve exact original text pieces. */
  spans?: SpeechSpan[];
  segmentSpans?: SpeechSpan[];
  provisional?: boolean;
}

export function absoluteSpeechSpans(spans: SpeechSpan[], startFrame: number) {
  return spans.map((span) => ({
    ...span,
    startSeconds:
      (Math.round(span.startSeconds * speechSampleRate) + startFrame) / speechSampleRate,
    endSeconds: (Math.round(span.endSeconds * speechSampleRate) + startFrame) / speechSampleRate,
  }));
}

/** Keep only a bounded editable suffix; never split an acoustic/text piece. */
export function partitionSpeechWindow(window: TimedSpeechWindow, beforeFrame: number) {
  if (
    !validWindow(window) ||
    !window.spans ||
    !Number.isSafeInteger(beforeFrame) ||
    beforeFrame < window.startFrame ||
    beforeFrame > window.endFrame
  )
    throw new Error("Cannot checkpoint invalid or untimed speech evidence.");
  const seconds = beforeFrame / speechSampleRate;
  const checkpointSpans = window.segmentSpans ?? window.spans;
  let index = checkpointSpans.findIndex((span) => span.endSeconds > seconds);
  if (index === -1) index = checkpointSpans.length;
  let committedFrame = beforeFrame;
  if (index < checkpointSpans.length) {
    committedFrame = Math.min(
      beforeFrame,
      Math.round(checkpointSpans[index]!.startSeconds * speechSampleRate),
    );
    // Token estimates can overlap. Retain the whole overlapping group rather
    // than claiming a committed span is covered by earlier source audio.
    while (
      index > 0 &&
      checkpointSpans[index - 1]!.endSeconds > committedFrame / speechSampleRate
    ) {
      index--;
      committedFrame = Math.min(
        committedFrame,
        Math.round(checkpointSpans[index]!.startSeconds * speechSampleRate),
      );
    }
  }
  const committedSpans = checkpointSpans.slice(0, index);
  const pendingSpans = checkpointSpans.slice(index);
  return {
    committedFrame,
    committedSpans,
    committedText: committedSpans.map((span) => span.text).join(""),
    pending:
      committedFrame < window.endFrame
        ? {
            startFrame: committedFrame,
            endFrame: window.endFrame,
            spans: pendingSpans,
            ...(window.segmentSpans ? { segmentSpans: pendingSpans } : {}),
            provisional: true,
            text: pendingSpans
              .map((span) => span.text)
              .join("")
              .trim(),
          }
        : undefined,
  };
}

function validWindow(window: TimedSpeechWindow) {
  if (
    !Number.isSafeInteger(window.startFrame) ||
    !Number.isSafeInteger(window.endFrame) ||
    window.startFrame < 0 ||
    window.endFrame <= window.startFrame
  )
    return false;
  for (const spans of [window.spans, window.segmentSpans]) {
    if (!spans) continue;
    let start = window.startFrame / speechSampleRate;
    let end = start;
    for (const span of spans) {
      if (
        !span.text.length ||
        span.text.includes("\0") ||
        !Number.isFinite(span.startSeconds) ||
        !Number.isFinite(span.endSeconds) ||
        span.startSeconds < start ||
        span.endSeconds < end ||
        span.endSeconds < span.startSeconds ||
        span.endSeconds > window.endFrame / speechSampleRate
      )
        return false;
      start = span.startSeconds;
      end = span.endSeconds;
    }
    if (
      spans
        .map((span) => span.text)
        .join("")
        .trim() !== window.text
    )
      return false;
  }
  return true;
}

function assembled(spans: SpeechSpan[], segmentSpans?: SpeechSpan[]) {
  return {
    kind: "resolved" as const,
    spans,
    ...(segmentSpans ? { segmentSpans } : {}),
    text: spans
      .map((span) => span.text)
      .join("")
      .trim(),
  };
}

function separatedSpans(previous: SpeechSpan[], current: SpeechSpan[]) {
  const last = previous.at(-1);
  const first = current[0];
  if (!last || !first || /\s$/u.test(last.text) || /^\s/u.test(first.text))
    return [...previous, ...current];
  return [...previous, { ...first, text: ` ${first.text}` }, ...current.slice(1)];
}

/**
 * Resolve only acoustically supported overlap, never deduplicate phrases by
 * text alone. Keep previous provisional until this returns resolved. A caller
 * may decode the complete provisional joined interval once, replacing that
 * bounded evidence. Failed coverage remains incomplete and retryable.
 */
export function reconcileSpeechBoundary(input: {
  previous: TimedSpeechWindow;
  current: TimedSpeechWindow;
  resolutionAttempts?: number;
}) {
  const { previous, current, resolutionAttempts = 0 } = input;
  if (!validWindow(previous) || !validWindow(current))
    return { kind: "unresolved" as const, reason: "Invalid speech window or timed coverage." };
  if (current.startFrame > previous.endFrame)
    return {
      kind: "unresolved" as const,
      reason: "An audio interval is missing between speech windows.",
    };
  if (current.startFrame <= previous.startFrame || current.endFrame <= previous.endFrame)
    return { kind: "unresolved" as const, reason: "Speech windows are not ordered forward." };
  const retry = () =>
    resolutionAttempts >= 1
      ? {
          kind: "unresolved" as const,
          reason: "Speech boundary remains ambiguous after bounded re-decoding.",
        }
      : current.endFrame - previous.startFrame > 90 * speechSampleRate
        ? {
            kind: "unresolved" as const,
            reason: "The provisional speech interval exceeds the bounded re-decoding budget.",
          }
        : {
            kind: "redecode" as const,
            startFrame: previous.startFrame,
            endFrame: current.endFrame,
          };
  if (previous.provisional && previous.text.trim()) return retry();
  if (current.startFrame === previous.endFrame) {
    // Untimed backends must select these non-overlap windows from the start.
    // Preserve all text, including an intentionally repeated boundary phrase.
    if (previous.spans && current.spans)
      return assembled(separatedSpans(previous.spans, current.spans));
    return {
      kind: "resolved" as const,
      spans: undefined,
      text: [previous.text, current.text].filter(Boolean).join(" "),
    };
  }

  if (!previous.spans || !current.spans) return retry();
  const overlapStart = current.startFrame / speechSampleRate;
  const overlapEnd = previous.endFrame / speechSampleRate;
  const old = previous.spans;
  const fresh = current.spans;
  const intersects = (span: SpeechSpan) =>
    span.endSeconds > overlapStart && span.startSeconds < overlapEnd;
  if (!old.some(intersects) && !fresh.some(intersects)) {
    // Both passes explicitly agree there was no text in the shared interval.
    return assembled(separatedSpans(old, fresh));
  }
  const matching = (a: SpeechSpan, b: SpeechSpan) =>
    a.text.trim().normalize("NFKC") === b.text.trim().normalize("NFKC") &&
    Math.abs(a.startSeconds - b.startSeconds) <= 0.35 &&
    Math.abs(a.endSeconds - b.endSeconds) <= 0.35;
  const candidates: {
    oldIndex: number;
    freshIndex: number;
    distance: number;
    alignment: number;
  }[] = [];
  for (let i = 0; i < old.length - 1; ++i) {
    if (!intersects(old[i]!)) continue;
    for (let j = 0; j < fresh.length - 1; ++j) {
      if (!intersects(fresh[j]!) || !matching(old[i]!, fresh[j]!)) continue;
      let length = 0;
      let lexicalPieces = 0;
      while (
        i + length < old.length &&
        j + length < fresh.length &&
        matching(old[i + length]!, fresh[j + length]!) &&
        intersects(old[i + length]!)
      ) {
        if (
          /[\p{L}\p{N}]/u.test(old[i + length]!.text) &&
          old[i + length]!.endSeconds - old[i + length]!.startSeconds >= 0.02 &&
          fresh[j + length]!.endSeconds - fresh[j + length]!.startSeconds >= 0.02
        )
          lexicalPieces++;
        length++;
      }
      if (lexicalPieces < 2) continue;
      for (let k = 0; k < length; ++k) {
        const oldIndex = i + k;
        const freshIndex = j + k;
        const next = fresh[freshIndex + 1];
        const anchor = old[oldIndex]!;
        if (
          next &&
          (next.startSeconds < anchor.startSeconds || next.endSeconds < anchor.endSeconds)
        )
          continue;
        candidates.push({
          oldIndex,
          freshIndex,
          alignment: i - j,
          distance: Math.abs(anchor.endSeconds - (overlapStart + overlapEnd) / 2),
        });
      }
    }
  }
  // Distinct repeated occurrences that fit the timing tolerance are ambiguous.
  if (!candidates.length || new Set(candidates.map((candidate) => candidate.alignment)).size !== 1)
    return retry();
  candidates.sort((a, b) => a.distance - b.distance || a.oldIndex - b.oldIndex);
  const anchor = candidates[0]!;
  return assembled([...old.slice(0, anchor.oldIndex + 1), ...fresh.slice(anchor.freshIndex + 1)]);
}
