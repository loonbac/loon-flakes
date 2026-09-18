import assert from "node:assert/strict";
import test from "node:test";
import { boundedSearchTimeout, registerBoundedSearch, unsafeGlobalSearch } from "./bounded-search.ts";

test("blocks whole-machine find scans that fan out through the Nix store", () => {
	assert.equal(unsafeGlobalSearch('find / -name "whatsapp.rs" 2>/dev/null | head -3'), true);
	assert.equal(unsafeGlobalSearch('cd rust && find /nix/store -name "events.rs"'), true);
	assert.equal(unsafeGlobalSearch("find $HOME -name '*.rs'"), true);
});

test("allows repository and precise store-object searches", () => {
	assert.equal(unsafeGlobalSearch("find rust/target/debug/build -name whatsapp.rs -print -quit"), false);
	assert.equal(unsafeGlobalSearch("find . -name '*.rs'"), false);
	assert.equal(unsafeGlobalSearch("find /nix/store/abc-package -name schema.json"), false);
	assert.equal(unsafeGlobalSearch("rg --files -uu rust/target/debug/build | rg whatsapp.rs"), false);
});

test("blocks rg file inventory from broad system roots", () => {
	assert.equal(unsafeGlobalSearch("rg --files / | rg whatsapp.rs"), true);
	assert.equal(unsafeGlobalSearch("rg --files -uu /nix/store | rg whatsapp.rs"), true);
});

test("caps recursive searches without lengthening a tighter caller timeout", () => {
	assert.equal(boundedSearchTimeout("find . -name '*.rs'", undefined), 30);
	assert.equal(boundedSearchTimeout("rg --files -uu rust/target", 120), 30);
	assert.equal(boundedSearchTimeout("grep -R needle src", 10), 10);
	assert.equal(boundedSearchTimeout("cargo test", undefined), undefined);
});

test("the extension blocks the observed find command and caps a safe retry", () => {
	const handlers = new Map<string, (event: any) => any>();
	registerBoundedSearch({
		on(name: string, handler: (event: any) => any) {
			handlers.set(name, handler);
		},
	} as any);

	const toolCall = handlers.get("tool_call");
	assert.ok(toolCall);
	const blocked = toolCall({
		toolName: "bash",
		input: { command: 'find / -name "whatsapp.rs" -path "*OUT*" 2>/dev/null | head -3' },
	});
	assert.equal(blocked.block, true);
	assert.match(blocked.reason, /rust\/target\/debug\/build/u);

	const safeInput = {
		command: "rg --files -uu rust/target/debug/build | rg '/waproto-[^/]+/out/whatsapp\\.rs$' | head -3",
	};
	assert.equal(toolCall({ toolName: "bash", input: safeInput }), undefined);
	assert.equal((safeInput as { timeout?: number }).timeout, 30);
});
