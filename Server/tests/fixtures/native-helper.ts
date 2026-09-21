// A real subprocess fixture. Production has no model-verification CLI bypass.
import { basename } from "node:path";
import { appendFileSync } from "node:fs";

const modelFlag = process.argv.indexOf("--model");
const mode = basename(process.argv[modelFlag + 1] ?? "valid");
const emit = (value: object) => process.stdout.write(JSON.stringify(value) + "\n");

if (mode === "no-ready") await new Promise(() => setInterval(() => {}, 10_000));
if (mode === "ignore-term") {
  appendFileSync(`${process.argv[modelFlag + 1]}.pids`, `${process.pid}\n`);
  process.on("SIGTERM", () => {});
  setInterval(() => {}, 10_000);
}
emit({ type: "ready", engineVersion: mode === "ignore-term" ? `pid:${process.pid}` : "fixture-1" });
let buffer = "";
for await (const chunk of process.stdin) {
  buffer += chunk.toString();
  let index: number;
  while ((index = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, index);
    buffer = buffer.slice(index + 1);
    const request = JSON.parse(line) as {
      id: string;
      type: string;
      vocabularyTerms?: string[];
      systemPrompt?: string;
    };
    if (mode === "no-result") continue;
    if (mode === "ignore-term") {
      setTimeout(() => emit({ type: "unexpected" }), 100);
      continue;
    }
    if (mode === "oversized") {
      process.stdout.write("x".repeat(70_000));
      continue;
    }
    if (mode === "invalid-json") {
      process.stdout.write("not json\n");
      continue;
    }
    if (mode === "unknown-event") {
      emit({ type: "unexpected" });
      continue;
    }
    if (mode === "stderr") process.stderr.write("private transcript diagnostics".repeat(70_000));
    emit({ type: "progress", id: "stale-request", value: 0.75 });
    emit({ type: "progress", id: request.id, value: -1 });
    emit({ type: "progress", id: request.id, value: 0.5 });
    emit({ type: "progress", id: request.id, value: 2 });
    emit({
      type: "result",
      id: "stale-request",
      text: "Wrong request.",
      duration: 2,
      elapsed: 0.1,
      language: "en",
      ...(request.type === "transcribe"
        ? { segmentSpans: [{ text: "Hello world.", startSeconds: 0, endSeconds: 2 }] }
        : {}),
    });
    if (request.type === "correct" && request.systemPrompt !== "Keep punctuation.") {
      emit({ type: "error", id: request.id, message: "Missing proofreading prompt." });
      continue;
    }
    if (request.type === "boundary") {
      emit({
        type: "result",
        id: request.id,
        duration: 45,
        ...(mode === "boundary" ? { boundarySeconds: 32.5 } : {}),
        ...(mode === "invalid-boundary" ? { boundarySeconds: 46 } : {}),
      });
      continue;
    }
    const terms = request.vocabularyTerms ?? [];
    const result = {
      type: "result",
      id: request.id,
      text: mode === "invalid-result" ? "\0bad" : "Hello world.",
      duration: 2,
      elapsed: 0.1,
      language: "en",
      ...(request.type === "transcribe"
        ? { segmentSpans: [{ text: "Hello world.", startSeconds: 0, endSeconds: 2 }] }
        : {}),
      ...(request.type === "transcribe" && mode !== "missing-spans"
        ? {
            spans:
              mode === "invalid-spans"
                ? [{ text: "Hello world.", startSeconds: 1, endSeconds: 3 }]
                : mode === "unordered-spans"
                  ? [
                      { text: "Hello", startSeconds: 1, endSeconds: 1.5 },
                      { text: " world.", startSeconds: 0, endSeconds: 1 },
                    ]
                  : mode === "incomplete-spans"
                    ? [{ text: "Hello", startSeconds: 0, endSeconds: 1 }]
                    : [
                        { text: "Hello", startSeconds: 0, endSeconds: 0.8 },
                        { text: " world.", startSeconds: 0.8, endSeconds: 2 },
                      ],
          }
        : {}),
      ...(request.type === "transcribe"
        ? {
            includedTerms: mode === "invalid-hints" ? ["invented"] : terms,
            omittedTerms: [],
            tokenCount: 1,
            tokenBudget: 223,
          }
        : {}),
    };
    if (mode === "split-json") {
      const encoded = JSON.stringify(result) + "\n";
      process.stdout.write(encoded.slice(0, 20));
      await new Promise((resolve) => setTimeout(resolve, 5));
      process.stdout.write(encoded.slice(20));
    } else emit(result);
  }
}
