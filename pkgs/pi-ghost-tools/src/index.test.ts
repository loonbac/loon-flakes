import { test } from "node:test";
import assert from "node:assert/strict";
import { GHOST_TOOLS, ghostErrorMessage } from "./index.ts";

// --- GHOST_TOOLS registry ---------------------------------------------------

test("registry has no duplicate ghost names", () => {
  const names = GHOST_TOOLS.map((g) => g.ghost);
  const dupes = names.filter((n, i) => names.indexOf(n) !== i);
  assert.deepEqual(dupes, [], `duplicate ghost names: ${dupes.join(", ")}`);
});

test("every ghost has a non-empty name and hint", () => {
  for (const g of GHOST_TOOLS) {
    assert.ok(g.ghost.length > 0, "ghost name must be non-empty");
    assert.ok(g.hint.length > 0, `hint for ${g.ghost} must be non-empty`);
    assert.ok(/^[A-Za-z_][A-Za-z0-9_.]*$/.test(g.ghost), `ghost name ${g.ghost} must be a valid identifier-ish token`);
  }
});

test("ghost names never collide with pi's real core tools", () => {
  const core = [
    "bash", "powershell", "read", "edit", "write", "grep", "find", "ls",
    "codemode", "todo", "web_search", "fetch_content", "source_check",
    "get_search_content", "google_search", "generate_image", "codegraph",
    "monitor", "job_list", "job_stop", "bash_background",
  ];
  const collisions = GHOST_TOOLS.map((g) => g.ghost).filter((n) => core.includes(n));
  assert.deepEqual(collisions, [], `ghosts must not shadow real tools: ${collisions.join(", ")}`);
});

test("the codememo family maps to codemode", () => {
  const codememo = GHOST_TOOLS.filter((g) => g.ghost.startsWith("codememo"));
  assert.ok(codememo.length >= 4, "expected the observed codememo family in the registry");
  for (const g of codememo) {
    assert.equal(g.real, "codemode", `${g.ghost} should map to codemode`);
  }
});

// --- ghostErrorMessage ------------------------------------------------------

test("error with a known real tool names the tool and the exact next action", () => {
  const codememo = GHOST_TOOLS.find((g) => g.ghost === "codememo");
  assert.ok(codememo);
  const msg = ghostErrorMessage(codememo);
  assert.ok(msg.includes('Tool "codememo" does not exist'), msg);
  assert.ok(msg.includes("do not retry it"), "must tell the model not to retry");
  assert.ok(msg.includes('"codemode"'), "must name the real tool");
  assert.ok(msg.includes("Re-issue the call"), "must demand a re-issue");
});

test("error without a known real tool says no equivalent exists", () => {
  const mcp = GHOST_TOOLS.find((g) => g.ghost === "mcp");
  assert.ok(mcp);
  assert.equal(mcp.real, null);
  const msg = ghostErrorMessage(mcp);
  assert.ok(msg.includes('Tool "mcp" does not exist'), msg);
  assert.ok(msg.includes("No known equivalent"), msg);
  assert.ok(!msg.includes('The tool you most likely meant'), "must not invent an equivalent");
});

test("error messages are deterministic for every registered ghost", () => {
  for (const g of GHOST_TOOLS) {
    const a = ghostErrorMessage(g);
    const b = ghostErrorMessage(g);
    assert.equal(a, b, `${g.ghost} message must be deterministic`);
    assert.ok(a.startsWith(`Tool "${g.ghost}" does not exist`), `${g.ghost}: ${a}`);
  }
});
