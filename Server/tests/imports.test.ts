import { afterEach, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, readdir, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type {
  GenerationRecord,
  PreferencesSnapshot,
  WisprFlowArtifactManifest,
  WisprFlowArtifactName,
  WisprFlowImportRequest,
} from "../src/api.ts";
import { WisprFlowImports } from "../src/imports.ts";
import { ensureDirectory, sha256 } from "../src/storage.ts";

const directories: string[] = [];
afterEach(async () => {
  for (const directory of directories.splice(0))
    await rm(directory, { recursive: true, force: true });
});
const preferences: PreferencesSnapshot = {
  revision: 0,
  preferences: {
    language: "en",
    proofreadingPrompt: "",
    vocabulary: "",
    dictionary: { lists: [] },
    textCorrectionEnabled: false,
    keepOriginalAudio: false,
  },
};
const sourceID = "11111111-1111-4111-8111-111111111111";
const wav = Buffer.from([
  0x52, 0x49, 0x46, 0x46, 0x26, 0, 0, 0, 0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20, 0x10, 0, 0,
  0, 1, 0, 1, 0, 0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0, 0x64, 0x61, 0x74, 0x61, 2, 0, 0,
  0, 0, 0,
]);
const json = (value: unknown) => Buffer.from(JSON.stringify(value));
const source = (sources: unknown[] = [], extra: Record<string, unknown> = {}) =>
  json({ schemaVersion: 1, provider: "wispr-flow", sourceID, sources, ...extra });
const manifest = (
  filename: WisprFlowArtifactName,
  data: Uint8Array,
): WisprFlowArtifactManifest => ({ filename, byteCount: data.length, sha256: sha256(data) });

async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "v07-typescript-imports-"));
  directories.push(directory);
  await ensureDirectory(join(directory, "generations"));
  const records = new Map<string, GenerationRecord>();
  const context = {
    dataDirectory: directory,
    getPreferences: () => preferences,
    getRecord: (id: string) => {
      const record = records.get(id);
      if (!record) throw new Error("Record not found");
      return record;
    },
    publish: (record: GenerationRecord) => {
      records.set(record.id, record);
    },
    requireDiskSpace: async () => {},
  };
  const imports = new WisprFlowImports(context);
  await imports.initialize();
  const restart = async () => {
    const next = new WisprFlowImports(context);
    await next.initialize();
    records.clear();
    for (const id of await readdir(join(directory, "generations"))) {
      const record: GenerationRecord = JSON.parse(
        await readFile(join(directory, "generations", id, "metadata.json"), "utf8"),
      );
      records.set(record.id, record);
      next.indexRecord(record);
    }
    return next;
  };
  return { imports, records, directory, restart };
}

function request(
  artifacts: [WisprFlowArtifactName, Buffer][],
  text = "Recovered words",
): WisprFlowImportRequest {
  return {
    sourceID,
    createdAt: "2026-01-04T00:00:00.000Z",
    finalText: text,
    rawText: text,
    sourceStatus: text ? "COMPLETED" : "FAILED",
    variantNames: text ? ["pastedText"] : [],
    artifacts: artifacts.map(([name, data]) => manifest(name, data)),
  };
}
async function transfer(
  imports: WisprFlowImports,
  artifacts: [WisprFlowArtifactName, Buffer][],
  text?: string,
  extra: Partial<WisprFlowImportRequest> = {},
) {
  const session = await imports.beginWisprFlowImport({ ...request(artifacts, text), ...extra });
  for (const [name, data] of artifacts)
    await imports.uploadWisprFlowArtifact(session.id, name, data);
  return imports.completeWisprFlowImport(session.id);
}

describe("Wispr Flow import compatibility", () => {
  test("reruns backfill media into the same durable record across restarts", async () => {
    const f = await fixture(),
      sourceJSON = source();
    const imported = await transfer(f.imports, [["source.json", sourceJSON]]);
    expect(imported.outcome).toBe("imported");
    const restarted = await f.restart();
    const enriched = await transfer(restarted, [
      ["source.json", sourceJSON],
      ["source.wav", wav],
    ]);
    expect(enriched.outcome).toBe("enriched");
    expect(enriched.record.id).toBe(imported.record.id);
    expect(enriched.record.importedSource?.artifactSHA256["source.wav"]).toBe(sha256(wav));
    expect(
      await readFile(join(f.directory, "generations", imported.record.id, "source.wav")),
    ).toEqual(wav);
    const afterBackfill = await f.restart();
    expect(
      afterBackfill.knownWisprFlowIDs({ sourceIDs: [sourceID.toUpperCase(), randomUUID()] })
        .knownSourceIDs,
    ).toEqual([sourceID.toUpperCase()]);
    expect(
      (
        await transfer(afterBackfill, [
          ["source.json", sourceJSON],
          ["source.wav", wav],
        ])
      ).outcome,
    ).toBe("skipped");
    expect(f.records.size).toBe(1);
  });

  test("metadata-only attempts preserve empty transcripts and source status", async () => {
    const f = await fixture();
    const result = await transfer(f.imports, [["source.json", source()]], "");
    expect(result.record.finalText).toBe("");
    expect(result.record.rawText).toBe("");
    expect(result.record.importedSource?.sourceStatus).toBe("FAILED");
    expect(result.record.inferenceAudio).toBeUndefined();
  });

  test("conflicting incoming media keeps the archived bytes and records missing version", async () => {
    const f = await fixture();
    const first = await transfer(
      f.imports,
      [
        ["source.json", source()],
        ["source.wav", wav],
      ],
      "First text",
    );
    const conflict = Buffer.from(wav);
    conflict[conflict.length - 1] = 1;
    const newerSource = source([{ syntheticVersion: 2 }]);
    const enriched = await transfer(
      f.imports,
      [
        ["source.json", newerSource],
        ["source.wav", conflict],
      ],
      "Corrected text",
    );
    expect(enriched.outcome).toBe("partial");
    expect(enriched.record.id).toBe(first.record.id);
    expect(enriched.record.finalText).toBe("Corrected text");
    expect(enriched.unarchivedArtifactNames).toEqual(["source.wav"]);
    expect(enriched.record.importedSource?.artifactSHA256["source.wav"]).toBe(sha256(wav));
    expect(enriched.record.importedSource?.unarchivedArtifactSHA256?.["source.wav"]).toBe(
      sha256(conflict),
    );
    expect(await readFile(join(f.directory, "generations", first.record.id, "source.wav"))).toEqual(
      wav,
    );
    const archived = JSON.parse(
      await readFile(join(f.directory, "generations", first.record.id, "source.json"), "utf8"),
    );
    expect(archived.archiveConflicts[0].status).toBe("not-archived");
    expect(
      (
        await transfer(
          f.imports,
          [
            ["source.json", newerSource],
            ["source.wav", conflict],
          ],
          "Corrected text",
        )
      ).outcome,
    ).toBe("partial");
    expect(f.records.size).toBe(1);
  });

  test("media backfill reconciles earlier omission while retaining provenance", async () => {
    const f = await fixture(),
      digest = sha256(wav);
    const sourceJSON = source(
      [
        {
          values: {
            audio: {
              type: "blob",
              byteCount: wav.length,
              sha256: digest,
              archiveStatus: "not-archived",
              archiveReason: "invalid-or-unavailable",
            },
          },
        },
      ],
      {
        archiveOmissions: [
          {
            artifact: "source.wav",
            sourceName: "flow.sqlite",
            sourceRowID: 1,
            observedByteCount: wav.length,
            observedSHA256: digest,
            reason: "invalid-or-unavailable",
            status: "not-archived",
          },
        ],
      },
    );
    const first = await transfer(f.imports, [["source.json", sourceJSON]], undefined, {
      unarchivedArtifacts: [manifest("source.wav", wav)],
    });
    expect(first.outcome).toBe("partial");
    const next = await transfer(f.imports, [
      ["source.json", sourceJSON],
      ["source.wav", wav],
    ]);
    expect(next.outcome).toBe("enriched");
    expect(next.record.id).toBe(first.record.id);
    expect(next.record.importedSource?.unarchivedArtifactSHA256).toEqual({});
    const archived = JSON.parse(
      await readFile(join(f.directory, "generations", next.record.id, "source.json"), "utf8"),
    );
    expect(archived.archiveOmissions[0].status).toBe("archived");
    expect(archived.sources[0].values.audio.artifact).toBe("source.wav");
    expect(archived.sources[0].values.audio.archiveReason).toBeUndefined();
  });

  test("later full row versions do not erase earlier compacted provenance", async () => {
    const f = await fixture();
    const partial = source(
      [
        {
          values: {
            largeMetadata: {
              type: "text",
              byteCount: 4_000_000,
              sha256: "c".repeat(64),
              archiveStatus: "not-archived",
              archiveReason: "exceeds-source-json-limit",
            },
          },
        },
      ],
      {
        provenanceStatus: "partial",
        provenanceOmittedFieldCount: 1,
        provenanceOmittedSourceCount: 0,
        provenanceOmittedMediaVersionCount: 0,
      },
    );
    const first = await transfer(f.imports, [["source.json", partial]]);
    expect(first.outcome).toBe("partial");
    expect(first.unarchivedArtifactNames).toEqual([]);
    expect((await transfer(f.imports, [["source.json", partial]])).outcome).toBe("partial");
    const full = source([
      { values: { largeMetadata: { type: "text", value: "Restored metadata" } } },
    ]);
    const next = await transfer(f.imports, [
      ["source.json", full],
      ["source.wav", wav],
    ]);
    expect(next.outcome).toBe("partial");
    const archived = JSON.parse(
      await readFile(join(f.directory, "generations", next.record.id, "source.json"), "utf8"),
    );
    expect(archived.sources).toHaveLength(2);
    expect(archived.provenanceOmittedFieldCount).toBe(1);
    expect(archived.provenanceStatus).toBe("partial");
  });

  test("incomplete provenance and undeclared omission digests cannot reach history", async () => {
    const f = await fixture();
    const invalidProvenance = source([], {
      provenanceStatus: "partial",
      provenanceOmittedSourceCount: 1,
      provenanceOmittedMediaVersionCount: 0,
    });
    const staged = await f.imports.beginWisprFlowImport(
      request([["source.json", invalidProvenance]]),
    );
    await expect(
      f.imports.uploadWisprFlowArtifact(staged.id, "source.json", invalidProvenance),
    ).rejects.toMatchObject({ code: "invalid_source_json" });
    await f.imports.cancelWisprFlowImport(staged.id);
    const bytes = source();
    const missing = await f.imports.beginWisprFlowImport({
      ...request([["source.json", bytes]]),
      unarchivedArtifacts: [manifest("source.wav", wav)],
    });
    await expect(
      f.imports.uploadWisprFlowArtifact(missing.id, "source.json", bytes),
    ).rejects.toMatchObject({ code: "invalid_source_json" });
    expect(f.records.size).toBe(0);
  });

  test("unknown built-in audio is an omission and cannot be uploaded", async () => {
    const f = await fixture();
    const omission: WisprFlowArtifactManifest = {
      filename: "built-in-audio.bin",
      byteCount: 128,
      sha256: "b".repeat(64),
    };
    const bytes = source([], {
      archiveOmissions: [
        {
          artifact: omission.filename,
          observedByteCount: omission.byteCount,
          observedSHA256: omission.sha256,
          status: "not-archived",
        },
      ],
    });
    const imported = await transfer(f.imports, [["source.json", bytes]], undefined, {
      unarchivedArtifacts: [omission],
    });
    expect(imported.outcome).toBe("partial");
    expect(imported.unarchivedArtifactNames).toEqual(["built-in-audio.bin"]);
    await expect(
      f.imports.beginWisprFlowImport({
        ...request([["source.json", bytes]]),
        artifacts: [manifest("source.json", bytes), omission],
      }),
    ).rejects.toMatchObject({ code: "invalid_artifact_manifest" });
  });

  test("malformed and changed artifacts remain unpublished", async () => {
    const f = await fixture(),
      bytes = source(),
      badWav = Buffer.from("not a WAV file");
    const staged = await f.imports.beginWisprFlowImport(
      request([
        ["source.json", bytes],
        ["source.wav", badWav],
      ]),
    );
    await f.imports.uploadWisprFlowArtifact(staged.id, "source.json", bytes);
    await expect(
      f.imports.uploadWisprFlowArtifact(staged.id, "source.wav", badWav),
    ).rejects.toMatchObject({ code: "invalid_source_wav" });
    await expect(f.imports.completeWisprFlowImport(staged.id)).rejects.toMatchObject({
      code: "incomplete_import",
    });
    await f.imports.cancelWisprFlowImport(staged.id);
    const changed = await f.imports.beginWisprFlowImport(request([["source.json", bytes]]));
    await f.imports.uploadWisprFlowArtifact(changed.id, "source.json", bytes);
    await writeFile(
      join(f.directory, "imports", "wispr-flow", "staging", changed.id, "source.json"),
      "{}",
    );
    await expect(f.imports.completeWisprFlowImport(changed.id)).rejects.toMatchObject({
      code: "staged_artifact_changed",
    });
    expect(f.records.size).toBe(0);
  });

  test("source versions normalize archive status before deduplication", async () => {
    const f = await fixture(),
      digest = sha256(wav);
    const missing = source([
      {
        values: {
          audio: {
            type: "blob",
            sha256: digest,
            byteCount: wav.length,
            archiveStatus: "not-archived",
            archiveReason: "invalid-or-unavailable",
          },
        },
      },
    ]);
    const first = await transfer(f.imports, [["source.json", missing]]);
    const available = source([
      {
        values: {
          audio: {
            type: "blob",
            sha256: digest,
            byteCount: wav.length,
            archiveStatus: "archived",
            artifact: "source.wav",
          },
        },
      },
    ]);
    await transfer(f.imports, [
      ["source.json", available],
      ["source.wav", wav],
    ]);
    const archived = JSON.parse(
      await readFile(join(f.directory, "generations", first.record.id, "source.json"), "utf8"),
    );
    expect(archived.sources).toHaveLength(1);
    expect(archived.sources[0].values.audio.archiveStatus).toBe("archived");
  });

  test("dictionary archives preserve immutable versions without changing preferences", async () => {
    const f = await fixture(),
      first = json({ provider: "wispr-flow", rows: [{ phrase: "a".repeat(300_000) }] }),
      second = json({ provider: "wispr-flow", rows: [{ phrase: "new" }] });
    const receipt = await f.imports.archiveWisprFlowDictionary(first);
    expect(receipt.byteCount).toBe(first.length);
    await f.imports.archiveWisprFlowDictionary(second);
    const root = join(f.directory, "imports", "wispr-flow");
    expect(await readFile(join(root, "dictionary.json"))).toEqual(second);
    expect(await readFile(join(root, "dictionary-versions", `${sha256(first)}.json`))).toEqual(
      first,
    );
    expect(preferences.revision).toBe(0);
    await writeFile(join(root, "dictionary-versions", `${sha256(first)}.json`), "tampered");
    await expect(f.imports.archiveWisprFlowDictionary(first)).rejects.toMatchObject({
      code: "invalid_dictionary_archive",
    });
  });

  test("restart rolls back interrupted directory replacement before loading records", async () => {
    const f = await fixture(),
      result = await transfer(f.imports, [["source.json", source()]]),
      stageID = randomUUID().toUpperCase();
    const transactions = join(f.directory, "imports", "wispr-flow", "transactions");
    await writeFile(
      join(transactions, `${stageID}.json`),
      JSON.stringify({ recordID: result.record.id, stageID }),
    );
    await rename(
      join(f.directory, "generations", result.record.id),
      join(transactions, `${stageID}.backup`),
    );
    const restarted = await f.restart();
    expect(restarted.knownWisprFlowIDs({ sourceIDs: [sourceID] }).knownSourceIDs).toEqual([
      sourceID,
    ]);
    expect(f.records.get(result.record.id)?.finalText).toBe("Recovered words");
    expect(await readdir(transactions)).toEqual([]);
  });

  test("symlink staging files are rejected without reading their targets", async () => {
    const f = await fixture(),
      bytes = source(),
      staged = await f.imports.beginWisprFlowImport(request([["source.json", bytes]]));
    await f.imports.uploadWisprFlowArtifact(staged.id, "source.json", bytes);
    const target = join(f.directory, "outside-source.json"),
      path = join(f.directory, "imports", "wispr-flow", "staging", staged.id, "source.json");
    await writeFile(target, bytes);
    await rm(path);
    await symlink(target, path);
    await expect(f.imports.completeWisprFlowImport(staged.id)).rejects.toMatchObject({
      code: "staged_artifact_changed",
    });
    expect(f.records.size).toBe(0);
    expect(await readFile(target)).toEqual(bytes);
  });

  test("admission bounds stages, source IDs, and metadata", async () => {
    const f = await fixture(),
      bytes = source();
    for (let i = 0; i < 16; i++)
      await f.imports.beginWisprFlowImport(request([["source.json", bytes]]));
    await expect(
      f.imports.beginWisprFlowImport(request([["source.json", bytes]])),
    ).rejects.toMatchObject({ status: 429 });
    expect(() => f.imports.knownWisprFlowIDs({ sourceIDs: Array(10_001).fill(sourceID) })).toThrow(
      "Check at most",
    );
    await f.restart();
    expect(await readdir(join(f.directory, "imports", "wispr-flow", "staging"))).toEqual([]);
  });
});
