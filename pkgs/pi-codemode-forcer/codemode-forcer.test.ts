import { test } from "node:test";
import assert from "node:assert/strict";
import { scriptSnippet } from "./codemode-forcer.ts";

test("scriptSnippet escapes backticks for QuickJS", () => {
  const input = { command: "echo `test` && ls" };
  const snippet = scriptSnippet("bash", input);
  
  // The snippet should contain escaped backticks, not bare ones
  assert.ok(!snippet.includes("`test`"), "should not contain bare backticks");
  assert.ok(snippet.includes("\\`x60test\\`x60"), "should contain escaped backticks");
});

test("scriptSnippet handles input without backticks", () => {
  const input = { command: "echo hello" };
  const snippet = scriptSnippet("bash", input);
  
  // Should work normally without backticks
  assert.ok(snippet.includes("echo hello"), "should contain the command");
  assert.ok(!snippet.includes("x60"), "should not add escapes when no backticks");
});

test("scriptSnippet handles nested backticks", () => {
  const input = { command: "echo `a` && echo `b`" };
  const snippet = scriptSnippet("bash", input);
  
  // All backticks should be escaped
  const matches = snippet.match(/`/g);
  assert.ok(!matches || matches.length === 0, "no bare backticks should remain");
});
