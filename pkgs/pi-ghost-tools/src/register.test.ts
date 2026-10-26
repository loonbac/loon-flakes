import { test } from "node:test";
import assert from "node:assert/strict";
import { GHOST_TOOLS } from "./index.ts";
import ghostTools from "./index.ts";

test("default export registers one stub per ghost and hides them all", () => {
  const registered: { name: string; hasLoadout: boolean }[] = [];
  const pi = {
    registerTool(def: {
      name: string;
      prepareLoadout?: (loadout: { declared: { name: string }[] }) => { hiddenDeclarations?: string[] };
    }) {
      registered.push({ name: def.name, hasLoadout: typeof def.prepareLoadout === "function" });
    },
  } as never;
  ghostTools(pi);
  assert.equal(registered.length, GHOST_TOOLS.length, "one stub per ghost");
  assert.equal(new Set(registered.map((r) => r.name)).size, GHOST_TOOLS.length, "names must be unique");
  const loadoutOwners = registered.filter((r) => r.hasLoadout);
  assert.equal(loadoutOwners.length, 1, "exactly one tool carries prepareLoadout");
});

test("prepareLoadout hides only declared ghosts", () => {
  let prepareLoadout: ((loadout: { declared: { name: string }[] }) => { hiddenDeclarations?: string[] }) | undefined;
  const pi = {
    registerTool(def: {
      name: string;
      prepareLoadout?: (loadout: { declared: { name: string }[] }) => { hiddenDeclarations?: string[] };
    }) {
      if (def.prepareLoadout) prepareLoadout = def.prepareLoadout;
    },
  } as never;
  ghostTools(pi);
  assert.ok(prepareLoadout, "prepareLoadout must be registered");
  const declared = [{ name: "codememo" }, { name: "codememo7" }, { name: "bash" }, { name: "run_code_cell" }];
  const result = prepareLoadout({ declared });
  assert.deepEqual(result.hiddenDeclarations?.sort(), ["codememo", "codememo7", "run_code_cell"].sort());
});

test("execute throws the actionable error for its ghost name", async () => {
  const executes: { name: string; run: () => Promise<never> }[] = [];
  const pi = {
    registerTool(def: {
      name: string;
      execute?: (toolCallId: string) => Promise<never>;
    }) {
      if (def.execute) executes.push({ name: def.name, run: () => def.execute!("tc-1") });
    },
  } as never;
  ghostTools(pi);
  const codememo = executes.find((e) => e.name === "codememo");
  assert.ok(codememo, "codememo stub must be registered");
  await assert.rejects(codememo.run(), (err: Error) => {
    assert.ok(err.message.includes('Tool "codememo" does not exist'), err.message);
    assert.ok(err.message.includes('"codemode"'), err.message);
    return true;
  });
});

test("PI_GHOST_TOOLS=0 disables the extension", () => {
  const prev = process.env.PI_GHOST_TOOLS;
  process.env.PI_GHOST_TOOLS = "0";
  try {
    let count = 0;
    const pi = { registerTool() { count += 1; } } as never;
    ghostTools(pi);
    assert.equal(count, 0, "no tools must be registered when disabled");
  } finally {
    if (prev === undefined) delete process.env.PI_GHOST_TOOLS;
    else process.env.PI_GHOST_TOOLS = prev;
  }
});
