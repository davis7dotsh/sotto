import { describe, expect, test } from "bun:test";
import {
  boundProposedText,
  evaluateCorrection,
  maxInputCharacters,
  modelHints,
  processingRecord,
} from "../src/domain/correction.ts";

// The pairs below mirror V07DomainTests/TextCorrectionPolicyTests.swift.
const accept = (original: string, candidate: string, preferredTerms: string[] = []) => {
  expect(evaluateCorrection(original!, candidate!, preferredTerms).rejectionReason).toBeUndefined();
};
const reject = (original: string, candidate: string, preferredTerms: string[] = []) => {
  expect(evaluateCorrection(original!, candidate!, preferredTerms).rejectionReason).toBeDefined();
};

describe("conservative correction policy", () => {
  test("accepts supported spelling, casing, contractions, and punctuation", () => {
    accept(
      "please open codecks and minimax settings for this project",
      "Please open Codex and MiniMax settings for this project.",
    );
    accept("Open codeks now.", "Open Codex now.", ["Codex"]);
    reject("Open codeks now.", "Open Codex now.");
    accept("I don't think we should ship this yet", "I don’t think we should ship this yet.");
    accept("I haven’t merged this change.", "I have not merged this change.");
    accept("I cannot merge this change.", "I can’t merge this change.");
    accept("Open codeks and mini max settings.", "Open Codex and MiniMax settings.", [
      "Codex",
      "MiniMax",
    ]);
    accept("Open Calendar, err, Codex now.", "Open Codex now.", ["Codex", "MiniMax"]);
  });

  test("cannot insert dictionary hints in place of unrelated content", () => {
    const context = "One is book the room. Three is pick up the keys. Two is send the invitation. ";
    const original =
      context +
      "Four is I need to get God, what's it called? I need to get the meeting room sorted so I need to go down there and figure out whether I can get this meeting room.";
    const candidate =
      context +
      "Four is I need to get Codex sorted so I need to go down there and figure out whether I can get this meeting room.";
    expect(evaluateCorrection(original, candidate, ["Codex"])).toEqual({
      rejectionReason: "The rewrite introduced an unsupported dictionary term.",
      verifiedRepairs: [],
    });
  });

  test("preserves paragraphs, list numbering, and quantities", () => {
    accept(
      "Here is the plan. First we test the microphone.\n3. Order 2 new cables.\n4. Spend $20.50 on adapters.\n7. Leave at 10:30.",
      "Here is the plan.\n\nFirst, we test the microphone.\n\n  3. Order 2 new cables.\n  4. Spend $20.50 on adapters.\n  7. Leave at 10:30.",
    );
    accept("- buy apples\n- buy oranges", "- Buy apples.\n- Buy oranges.");
  });

  test("rejects empty, control token, commentary, and oversized output", () => {
    const original = "Please open the microphone settings.";
    for (const candidate of [
      "",
      " \n ",
      "<|im_start|>Please open the microphone settings.",
      "<think>check</think> Please open the microphone settings.",
      "a".repeat(12_001),
    ])
      reject(original!, candidate!);
    reject("...", "Something new.");
    for (const prefix of [
      "Here is",
      "Here's",
      "Corrected text:",
      "Corrected transcript:",
      "Sure,",
      "Certainly,",
    ]) {
      expect(evaluateCorrection(original, `${prefix} ${original}`).rejectionReason).toBe(
        "The text model added commentary.",
      );
    }
  });

  test("bounds dense Unicode token matrices and unbounded graphemes", () => {
    const dense = "a\u0301".repeat(maxInputCharacters);
    expect(evaluateCorrection(dense, dense).rejectionReason).toBe(
      "The rewrite was too complex to validate.",
    );
    expect(evaluateCorrection("\u0915\u094D\u200D".repeat(9_000), "Hello.").rejectionReason).toBe(
      "The source was too long to validate.",
    );
    expect(evaluateCorrection("Hello.", "\u0915\u094D\u200D".repeat(17_000)).rejectionReason).toBe(
      "The rewrite was too long.",
    );
  });

  test("accepts long ordinary dictation but bounds ambiguous repair scans", () => {
    const ordinary = "Please preserve every recorded answer. ".repeat(150);
    accept(ordinary, ordinary.replaceAll(". ", ".\n"));
    expect(evaluateCorrection("a, er, b, ".repeat(500), "a b ".repeat(500))).toEqual({
      rejectionReason: "The rewrite was too complex to validate.",
      verifiedRepairs: [],
    });
  });

  test("rejects changed numeric signs, currencies, percentages, and written quantities", () => {
    for (const [original, candidate] of [
      [
        "Please order 25 microphones for the project.",
        "Please order 26 microphones for the project.",
      ],
      ["Please arrive at 10:30 for the meeting.", "Please arrive at 10:00 for the meeting."],
      ["The total for this purchase is $20.", "The total for this purchase is €20."],
      ["Set the temperature to -20 degrees now.", "Set the temperature to 20 degrees now."],
      ["Set the progress indicator to 20% now.", "Set the progress indicator to 20 now."],
      ["We need two microphones for the project.", "We need three microphones for the project."],
      ["Order ٢ new microphones for the project.", "Order ٣ new microphones for the project."],
    ])
      reject(original!, candidate!);
  });

  test("rejects renumbered, removed, merged, reordered, or restyled lists", () => {
    const original = "3. Order apples.\n4. Order oranges.\n7. Order syrup.";
    for (const candidate of [
      "1. Order apples.\n2. Order oranges.\n3. Order syrup.",
      "3. Order apples.\n4. Order oranges and syrup.",
      "3. Order apples. 4. Order oranges. 7. Order syrup.",
      "- Order apples.\n- Order oranges.\n- Order syrup.",
    ])
      reject(original!, candidate!);
    reject("- Order apples.\n- Order oranges.", "• Order apples.\n• Order oranges.");
    reject(
      "1. Start the local service.\n2. Delete the old recordings.",
      "1. Delete the old recordings.\n2. Start the local service.",
    );
  });

  test("rejects answers, substantial removal, and reordered wording", () => {
    const original =
      "Please explain how to configure this new local service on my Mac and how to keep it running when I close the window.";
    for (const candidate of [
      "Open Settings, enable the service, and turn on background access.",
      "Please explain how to configure this service.",
      `Here is the corrected text: ${original}`,
    ])
      reject(original!, candidate!);
    reject(
      "Please start the local service before deleting the old recordings.",
      "Before deleting the local service please start the old recordings.",
    );
  });

  test("preserves preferred term occurrence counts", () => {
    const original = "Please open MiniMax and compare the local model settings with MiniMax again.";
    accept(
      original,
      "Please open MiniMax, and compare the local model settings with MiniMax again.",
      ["MiniMax"],
    );
    reject(
      original,
      "Please open OpenAI and compare the local model settings with MiniMax again.",
      ["MiniMax"],
    );
    reject(
      "Please open Codex, and then close the settings window.",
      "Please open Codex and Codex, and then close the settings window.",
      ["Codex"],
    );
    accept("Please open A+B and C.D.", "Please open A+B, and C.D.", ["A+B", "C.D"]);
    reject("Please open A+B and C.D.", "Please open A+B and CxD.", ["A+B", "C.D"]);
  });

  test("matches Foundation Unicode casing and full casefold occurrence checks", () => {
    expect(
      evaluateCorrection("Please open ΣΣΣΣ now.", "Please open σσσς now.", ["ΣΣΣΣ"])
        .rejectionReason,
    ).toBe("The rewrite removed an answer or sentence.");
    expect(
      evaluateCorrection("Please open İİİİ now.", "Please open i\u0307i\u0307i\u0307i\u0307 now.", [
        "İİİİ",
      ]).rejectionReason,
    ).toBe("The rewrite changed too much text.");
    expect(
      evaluateCorrection("Please open Café now.", "Please open Cafe\u0301 now.", ["Café"])
        .rejectionReason,
    ).toBe("The rewrite changed a dictionary term.");
  });

  test("joins preferred fragments only across horizontal whitespace", () => {
    for (const original of [
      "New. York.",
      "New, York.",
      "New; York.",
      "New-York.",
      "New\nYork.",
      "New\r\nYork.",
    ])
      reject(original, "NewYork.", ["NewYork"]);
    for (const original of ["New York.", "New\tYork."]) accept(original, "NewYork.", ["NewYork"]);
    accept("Please open mini max.", "Please open MiniMax.", ["MiniMax"]);
  });

  test("keeps short answers even beside long surviving context", () => {
    const context =
      "Keep the existing server running while we review the history and compare the recorded audio against the finished transcript because the whole discussion matters for our implementation and for the next review of the feature.";
    for (const answers of ["A. Agreed. A. Agreed. A. Agreed.", "A\nAgreed\nA\nAgreed\nA\nAgreed"]) {
      expect(evaluateCorrection(`${answers}\n${context}`, context).rejectionReason).toBe(
        "The rewrite removed an answer or sentence.",
      );
      reject(`${answers}\n${context}`, `A. Agreed. ${context}`);
    }
    accept(`A. Agreed. A. Agreed. ${context}`, `A, agreed; A, agreed. ${context}`);
    reject(`Keep the audio. ${context}`, context);
    const startsWithA =
      "A detailed implementation plan should preserve the audio and every individual answer during processing and review.";
    reject(`A. ${startsWithA}`, startsWithA);
    const endsWithAudio =
      "We should preserve the original recording for review while processing every individual answer in the audio.";
    reject(`${endsWithAudio} Audio.`, endsWithAudio);
  });

  test("keeps negations attached to the original action", () => {
    for (const [original, candidate] of [
      [
        "Please do not delete the archived audio recordings.",
        "Please do delete the archived audio recordings.",
      ],
      [
        "Please delete the archived audio recordings after review.",
        "Please never delete the archived audio recordings after review.",
      ],
      [
        "We should work without uploading the recordings anywhere.",
        "We should work with uploading the recordings anywhere.",
      ],
      ["I don't think the service should run today.", "I think the service should run today."],
      [
        "I cannot merge this change before the review.",
        "I can merge this change before the review.",
      ],
      [
        "There is nothing we should change in this section.",
        "There is something we should change in this section.",
      ],
      [
        "Do not merge the branch and do deploy the service.",
        "Do merge the branch and do not deploy the service.",
      ],
      [
        "Nobody should deploy this service before the review.",
        "Somebody should deploy this service before the review.",
      ],
      ["I do not want to merge this change.", "I do want not to merge this change."],
    ])
      reject(original!, candidate!);
    expect(
      evaluateCorrection(
        "Do not merge the branch and do deploy the service.",
        "Do merge the branch and do not deploy the service.",
      ).rejectionReason,
    ).toBe("The rewrite moved a negation to different wording.");
  });
});

describe("verified spoken repairs", () => {
  const acceptedRepairs = [
    ["Orange, err, yellow.", "Yellow."],
    ["I want the color to be orange, er, yellow.", "I want the color to be yellow."],
    ["I want the color to be orange, erm, yellow today.", "I want the color to be yellow today."],
    ["Use orange, sorry, yellow.", "Use yellow."],
    ["Orange, sorry, yellow.", "Yellow."],
    ["42, sorry, 24.", "24."],
    ["Make it forty two, sorry, twenty four before lunch.", "Make it twenty four before lunch."],
    ["Make it 42, I mean, 24.", "Make it 24."],
    ["Make it 42, correction, 24 before lunch.", "Make it 24 before lunch."],
    ["I cannot merge this, sorry, I can merge this.", "I can merge this."],
    ["I can merge this, sorry, I cannot merge this.", "I cannot merge this."],
    ["I can merge this, I mean, I cannot merge this.", "I cannot merge this."],
    [
      "We should not ship this, correction, we should ship this tomorrow.",
      "We should ship this tomorrow.",
    ],
  ];
  test.each(acceptedRepairs)("accepts a bounded anchored repair: %s", (original, candidate) => {
    const evaluation = evaluateCorrection(original!, candidate!);
    expect(evaluation.rejectionReason).toBeUndefined();
    expect(evaluation.verifiedRepairs).toHaveLength(1);
  });

  test("multiple repairs stay inside their answer units", () => {
    const original =
      "Set the count to 42, sorry, 24 before lunch. I cannot merge this, correction, I can merge this after review. Use orange, err, yellow for the border.";
    const candidate =
      "Set the count to 24 before lunch. I can merge this after review. Use yellow for the border.";
    expect(evaluateCorrection(original!, candidate!).rejectionReason).toBeUndefined();
    expect(evaluateCorrection(original!, candidate!).verifiedRepairs).toHaveLength(3);
    expect(
      evaluateCorrection("Orange, err, yellow. Blue, err, green.", "Yellow. Green.")
        .verifiedRepairs,
    ).toHaveLength(2);
  });

  test("reports UTF16 source offsets, including astral characters before the repair", () => {
    const original = "😀 Make it 42, sorry, 24.";
    const result = evaluateCorrection(original, "😀 Make it 24.");
    expect(result.rejectionReason).toBeUndefined();
    expect(result.verifiedRepairs).toEqual([
      {
        abandoned: { locationUTF16: 11, lengthUTF16: 2, text: "42" },
        cue: { locationUTF16: 15, lengthUTF16: 5, text: "sorry" },
        replacement: { locationUTF16: 22, lengthUTF16: 2, text: "24" },
      },
    ]);
  });

  test("repair exceptions do not exempt unrelated numbers, negations, answers, or lists", () => {
    for (const [original, candidate] of [
      ["Make it 42, err, 24. Keep the other 15 records.", "Make it 24. Keep the other 16 records."],
      ["Make it 42, err, 24. Never merge the result.", "Make it 24. Merge the result."],
      [
        "Make it 42, err, 24. Agreed. Keep every other word of this lengthy final paragraph because it documents the details for the current decision.",
        "Make it 24. Keep every other word of this lengthy final paragraph because it documents the details for the current decision.",
      ],
      ["5. Apples.\n6. Oranges, err, 7. Pears.", "5. Apples.\n7. Pears."],
    ])
      reject(original!, candidate!);
  });

  test("alternatives, identifiers, quotes, apologies, and unrelated clauses are protected", () => {
    const rejectedRepairs = [
      ["Orange or yellow.", "Yellow."],
      ["Use the err variable.", "Use the variable."],
      ["Orange, ‘err’, yellow.", "Yellow."],
      ["Orange, `err`, yellow.", "Yellow."],
      ["I am sorry, I cannot merge this.", "I can merge this."],
      ["Orange. Sorry, yellow.", "Yellow."],
      ["I will definitely, sorry, I will cancel the meeting.", "I will cancel the meeting."],
      ["I have to leave, sorry, I missed the meeting.", "I missed the meeting."],
      ["I will not attend, sorry, I have an appointment.", "I have an appointment."],
      ["Keep 42 records, sorry, I cannot help.", "I cannot help."],
      ["Agreed, sorry, I was distracted.", "I was distracted."],
      ["A, sorry, Davis interrupted.", "Davis interrupted."],
      ...["er", "err", "erm", "sorry"].map((cue) => [
        `Agreed, ${cue}, I was distracted.`,
        "I was distracted.",
      ]),
    ];
    for (const [original, candidate] of rejectedRepairs) {
      const evaluation = evaluateCorrection(original!, candidate!);
      expect(evaluation.rejectionReason).toBeDefined();
      expect(evaluation.verifiedRepairs).toHaveLength(0);
    }
    accept("I want the color to be orange or yellow.", "I want the color to be orange or yellow.");
  });

  test("hyphenated components are protected; spaced dashes can delimit a repair", () => {
    for (const cue of ["er", "err", "erm", "sorry", "correction", "I mean"]) {
      for (const original of [
        `Use error-${cue}-code.`,
        `Use error-${cue}, code.`,
        `Use error, ${cue}-code.`,
      ]) {
        expect(evaluateCorrection(original, "Use code.").verifiedRepairs).toHaveLength(0);
        reject(original, "Use code.");
      }
    }
    for (const cue of ["um", "uh", "er", "err", "erm"]) {
      reject(`Use error-${cue}-code.`, "Use error-code.");
      reject(`${cue}-code.`, "Code.");
      reject(`Use code-${cue}.`, "Use code.");
    }
    const evaluation = evaluateCorrection("Use orange - correction - yellow.", "Use yellow.");
    expect(evaluation.rejectionReason).toBeUndefined();
    expect(evaluation.verifiedRepairs).toHaveLength(1);
    accept("Please - erm - open settings.", "Please open settings.");
  });

  test("uses ICU cue boundaries around combining marks and format controls", () => {
    for (const boundary of ["\u0301", "\u200C", "\u200D"]) {
      const result = evaluateCorrection(`Use orange, ${boundary}err, yellow.`, "Use yellow.");
      expect(result.rejectionReason).toBeUndefined();
      expect(result.verifiedRepairs).toHaveLength(1);
    }
    expect(
      evaluateCorrection("Use orange, err\u200B, yellow.", "Use yellow.").verifiedRepairs,
    ).toHaveLength(0);
    reject("Use orange, err\u200B, yellow.", "Use yellow.");
  });

  test("isolated hesitation removal requires surviving anchors", () => {
    for (const [original, candidate] of [
      ["Um, hello.", "Hello."],
      ["Er, open settings.", "Open settings."],
      ["Please, erm, open settings.", "Please open settings."],
      ["Open settings, uh.", "Open settings."],
    ]) {
      expect(evaluateCorrection(original!, candidate!)).toEqual({
        rejectionReason: undefined,
        verifiedRepairs: [],
      });
    }
    reject("Print the err variable.", "Print the variable.");
    reject("Print ‘err’, please.", "Print, please.");
  });
});

describe("bounded model hints and diagnostics", () => {
  test("hint limits keep complete terms and count UTF8 bytes", () => {
    const terms = Array.from({ length: 90 }, (_, index) => `Tool${index}`);
    expect(modelHints(terms)).toEqual(terms.slice(0, 80));
    expect(modelHints(["語".repeat(86), "Codex"])).toEqual(["Codex"]);
    const fillsBudget = Array.from(
      { length: 64 },
      (_, index) => `${String(index).padStart(2, "0")}${"a".repeat(62)}`,
    );
    expect(modelHints([...fillsBudget, "Codex"])).toEqual(fillsBudget);
    expect(modelHints(["é".repeat(128)])).toEqual(["é".repeat(128)]);
  });

  test("diagnostics cap proposals and repair count", () => {
    const repair = evaluateCorrection("42, sorry, 24.", "24.").verifiedRepairs[0]!;
    const record = processingRecord({
      dictionaryTerms: [],
      dictionaryChangedText: false,
      inputText: "42, sorry, 24.",
      outputText: "24.",
      enabled: true,
      status: "applied",
      proposedText: "x".repeat(13_000),
      verifiedRepairs: Array.from({ length: 12 }, () => repair),
    });
    expect(record.proposedText).toHaveLength(12_000);
    expect(record.verifiedRepairs).toHaveLength(8);
    expect(record.verifiedRepairs?.[0]?.abandoned.text).toBe("42");
    const oldRecord = processingRecord({
      dictionaryTerms: [],
      dictionaryChangedText: false,
      inputText: "hello",
      outputText: "Hello.",
      enabled: true,
      status: "applied",
    });
    expect(Object.hasOwn(oldRecord, "proposedText")).toBe(false);
  });

  test("proposal clipping preserves Unicode and does not split surrogate pairs", () => {
    expect(boundProposedText("Café 👨‍👩‍👧‍👦")).toBe("Café 👨‍👩‍👧‍👦");
    const prefix = `a${"\u0301".repeat(maxInputCharacters * 8 - 2)}`;
    expect(boundProposedText(`${prefix}😀`)).toBe(prefix);
    const expansion = `a${"\u0301".repeat(2_048)} `.repeat(300);
    const bounded = boundProposedText(expansion);
    expect(bounded.length).toBeLessThanOrEqual(48_000);
    expect(expansion.startsWith(bounded)).toBe(true);
    expect(new TextEncoder().encode(JSON.stringify({ proposedText: bounded })).length).toBeLessThan(
      256 * 1_024,
    );
  });
});
