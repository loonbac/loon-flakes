import { appendFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// ---------------------------------------------------------------------------
// pi-ghost-tools
//
// Some models (observed: deepseek-ai/DeepSeek-V4.1-Flash-1017) hallucinate tool
// names: they call `codememo`, `codememo7`, `codememo_placeholder17`,
// `run_code_cell`, tools that do not exist. pi-agent-core answers
// `Tool X not found` BEFORE any extension hook can see the call, so the model
// retries the same wrong name up to 4 times in a row (4 wasted turns, 4 error
// lines in the UI) before it recovers on its own.
//
// This extension registers a stub for every hallucinated name. The stub:
//  - is active + callable (so pi-agent-core's lookup finds it),
//  - is hidden from the LLM request via prepareLoadout.hiddenDeclarations (so it
//    never adds noise to the system prompt or tool declarations),
//  - but if the model hallucinates the name anyway, it executes and returns an
//    actionable error that names the real tool, breaking the retry loop on the
//    FIRST failure instead of the fourth.
//
// Hallucinated names were collected from real session transcripts
// (~/.pi/agent/sessions/*/*.jsonl, 2026-10-17..26). To add a name: append it
// to GHOST_TOOLS below with the real tool it was probably meant to be.
//
// Escape hatch: PI_GHOST_TOOLS=0 disables the extension entirely.
// Decisions are appended to ~/.pi/agent/ghost-tools.log (0600).
// ---------------------------------------------------------------------------

interface GhostTool {
  /** Name the model hallucinates. */
  ghost: string;
  /** Real tool the model most likely meant, or null when unknown. */
  real: string | null;
  /** One-line hint shown to the model. */
  hint: string;
}

/**
 * Registry of hallucinated tool names.
 *
 * `real: null` means we could not tell what the model meant; the stub then
 * only says the tool does not exist and asks for a re-issue with a valid name.
 */
export const GHOST_TOOLS: readonly GhostTool[] = [
  { ghost: "codememo", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo3", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo4", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo5", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo6", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo7", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo8", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo9", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo10", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo11", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_dummy", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_dummy2", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder5", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder6", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder7", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder8", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder9", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder10", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder11", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder12", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder13", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder14", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder15", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder16", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codememo_placeholder17", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "codemap_placeholder", real: "codegraph", hint: "codegraph explores the repo graph" },
  { ghost: "run_code_cell", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "run_code", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "script", real: "codemode", hint: "codemode runs JS via tools.* inside one script" },
  { ghost: "mcp", real: null, hint: "MCP tools are namespaced mcp__<server>__<tool>; check `pi mcp list`" },
  { ghost: "mcp__lida", real: null, hint: "MCP tools are namespaced mcp__<server>__<tool>; check `pi mcp list`" },
  { ghost: "tools.find", real: "find", hint: "find is the standalone tool; inside codemode scripts use tools.find" },
  { ghost: "git_diff_unstaged", real: "bash", hint: "use bash: git diff (the forcer routes bash through codemode)" },
  { ghost: "list_channels", real: null, hint: "not a Pi tool in this session; verify the MCP server is connected" },
];

/**
 * The exact error text the model receives. Deterministic (no model call),
 * so tests can assert it byte-for-byte.
 */
export function ghostErrorMessage(ghost: GhostTool): string {
  const head = `Tool "${ghost.ghost}" does not exist. You hallucinated this name; do not retry it.`;
  if (ghost.real === null) {
    return `${head} No known equivalent in this session. Re-issue the call with a tool that exists in the current tool declarations.`;
  }
  return `${head} The tool you most likely meant is "${ghost.real}": ${ghost.hint}. Re-issue the call with that exact name.`;
}

/** Trace one line per intercepted ghost call so the fix is measurable. */
async function trace(entry: Record<string, unknown>): Promise<void> {
  const file = process.env.PI_GHOST_TOOLS_LOG || join(homedir(), ".pi", "agent", "ghost-tools.log");
  const line = JSON.stringify({ at: new Date().toISOString(), ...entry }) + "\n";
  await appendFile(file, line, { mode: 0o600 }).catch(() => {});
}

export default function ghostTools(pi: ExtensionAPI): void {
  if (process.env.PI_GHOST_TOOLS === "0") return;
  if (GHOST_TOOLS.length === 0) return;

  const ghostNames = GHOST_TOOLS.map((g) => g.ghost);
  const ghostByName = new Map(GHOST_TOOLS.map((g) => [g.ghost, g]));

  pi.registerTool({
    name: "codememo",
    label: "Ghost tool (hallucinated)",
    description:
      "Placeholder for a hallucinated tool name. Never declared to the model: it exists only so a call to a wrong name returns an actionable error instead of pi's generic 'Tool X not found'.",
    parameters: Type.Object({}, { additionalProperties: true }),
    // The first ghost registered carries the shared prepareLoadout for ALL ghosts.
    prepareLoadout(loadout) {
      const declared = new Set(loadout.declared.map((tool) => tool.name));
      return { hiddenDeclarations: ghostNames.filter((name) => declared.has(name)) };
    },
    async execute(toolCallId) {
      // Every ghost re-registers under its own name below; this execute only
      // runs for the name it was registered with, so recover it from the call.
      const ghost = ghostByName.get("codememo");
      if (!ghost) return { content: [{ type: "text" as const, text: "ghost registry empty" }] };
      await trace({ event: "intercepted", ghost: ghost.ghost, toolCallId, real: ghost.real });
      throw new Error(ghostErrorMessage(ghost));
    },
  });

  // Register the remaining ghosts. Each gets its own execute that throws the
  // per-name message; prepareLoadout from the first stub hides them all.
  for (const ghost of GHOST_TOOLS) {
    if (ghost.ghost === "codememo") continue;
    pi.registerTool({
      name: ghost.ghost,
      label: "Ghost tool (hallucinated)",
      description: `Placeholder for the hallucinated tool name "${ghost.ghost}". Not declared to the model.`,
      parameters: Type.Object({}, { additionalProperties: true }),
      async execute(toolCallId) {
        await trace({ event: "intercepted", ghost: ghost.ghost, toolCallId, real: ghost.real });
        throw new Error(ghostErrorMessage(ghost));
      },
    });
  }
}
