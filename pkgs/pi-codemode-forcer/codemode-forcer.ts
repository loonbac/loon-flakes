/**
 * Codemode Forcer
 *
 * Makes `codemode` the only path for reversible execution work, while keeping
 * host-bound tools reachable as ordinary tool calls.
 *
 * Both rules are decided in the `tool_call` hook, before the tool executes, and
 * both are pure name checks: no model judgement, no retry loop, no hidden state.
 *
 *  1. An execution tool called natively is blocked with a ready-to-paste script.
 *     Nothing has run at that point, so the only cost is re-emitting the same
 *     operation inside one codemode call. Batching then becomes the cheap path
 *     instead of an optional virtue.
 *
 *  2. A host-bound tool called from inside a script is blocked, because it needs
 *     the Pi host (a UI prompt, a consent round-trip or a relay). Calls the script
 *     made before that point already ran and stay done; only the host call is
 *     reissued natively.
 *
 * `parentToolCallId` is set by Pi itself when another tool issued the call, so
 * the distinction between "the model called it" and "a script called it" is exact.
 *
 * Escape hatch: PI_CODEMODE_FORCE=0 disables enforcement for one invocation.
 */

import { appendFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Append one line per block so enforcement is measurable instead of assumed. */
function trace(rule: string, tool: string, fromScript: boolean): void {
	const file = process.env.PI_CODEMODE_FORCE_LOG || join(homedir(), ".pi", "agent", "codemode-forcer.log");
	const line = JSON.stringify({ at: new Date().toISOString(), rule, tool, fromScript }) + "\n";
	void appendFile(file, line, { mode: 0o600 }).catch(() => {});
}

/** Tools whose work is reversible and cheap to batch: always go through a script. */
const SCRIPT_ONLY = new Set([
	"bash",
	"bash_background",
	"read",
	"edit",
	"write",
	"grep",
	"find",
	"ls",
]);

/**
 * Tools that need the Pi host and cannot work from inside a sandboxed script:
 * they prompt the user, open a consent dialog, drive the session or prompt UI,
 * own a child-process registry, or publish cross-session state.
 *
 * The rule is about the contract, not about a guess: these tools talk to the
 * host process or to a human. Pure reads that only return data (get_goal,
 * subagent_status, subagent_result, subagent_list_*, job_list, mem_*, todo,
 * typesafe_*, codegraph, web_*) stay callable from scripts on purpose —
 * blocking them would cost a turn and buy nothing.
 *
 * Inventory taken from `getAllTools()` in this session (75 tools configured,
 * 72 active), not from memory.
 */
const HOST_ONLY = new Set([
	// Human interaction and consent.
	"ask_user_choice",
	"ask_user_question",
	"request_secret",
	// Native review authority: the host relays every capture.
	"gentle_review",
	"gentle_review_capture",
	"gentle_review_capture_group",
	"gentle_review_scope",
	// Session and prompt-chrome state owned by Pi.
	"gentle_odd_phase",
	"create_goal",
	"update_goal",
	"session_worktree_register",
	"web_enable",
	// Child-process registry and background jobs spawned by the host.
	"subagent_run",
	"subagent_continue",
	"subagent_cancel",
	"subagent_send_message",
	"subagent_reply",
	"monitor",
	"job_stop",
	// Cross-session coordination through the host profile.
	"orchestrator_session_id",
	"orchestrator_send_message",
	"orchestrator_consult",
]);

/** Render the tool call the model just attempted as a script line. */
function scriptSnippet(toolName: string, input: Record<string, unknown>): string {
	const args = JSON.stringify(input ?? {}, null, 2)
		.split("\n")
		.map((line, index) => (index === 0 ? line : `  ${line}`))
		.join("\n");
	const method = toolName.replace(/[^A-Za-z0-9_]/g, "_");
	return `await tools.${method}(${args});`;
}

export default function (pi: ExtensionAPI) {
	if (process.env.PI_CODEMODE_FORCE === "0") return;

	pi.on("tool_call", (event) => {
		const fromScript = typeof event.parentToolCallId === "string";
		const name = event.toolName;

		// Rule 2: host-bound tool reached from a script.
		if (fromScript && HOST_ONLY.has(name)) {
			trace("host-inside-script", name, true);
			return {
				block: true,
				reason: [
					`Blocked: "${name}" needs the Pi host (user prompt, consent or relay) and cannot run inside a codemode script.`,
					"Issue it as a native tool call in your next turn.",
					"Any call your script made before this one already ran and stays done; only this call needs reissuing.",
				].join(" "),
			};
		}

		// Rule 1: execution tool called natively.
		if (!fromScript && SCRIPT_ONLY.has(name)) {
			trace("native-execution", name, false);
			return {
				block: true,
				reason: [
					`Blocked before execution: run "${name}" through a codemode script.`,
					"Nothing has executed yet, so nothing needs redoing.",
					"Send one codemode call like this:",
					"",
					scriptSnippet(name, (event.input ?? {}) as Record<string, unknown>),
					"",
					"Put every independent operation of this step in that same script",
					"(Promise.allSettled over reads, bash calls and edits that do not depend on each other)",
					"so the whole step costs one turn instead of one turn per command.",
				].join("\n"),
			};
		}

		return undefined;
	});
}
