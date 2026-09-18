import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const SEARCH_TIMEOUT_SECONDS = 30;

const SEARCH_GUIDANCE = `Repository search safety:
- Never run recursive searches from /, /home, /nix, /nix/store, $HOME, or ~.
- Prefer Pi's find/grep tools. In bash, use rg/rg --files with an explicit repository-relative root.
- Include ignored build output only when needed with: rg --files -uu <bounded-root>.
- For generated Rust files, search the project build tree first, for example: rg --files -uu rust/target/debug/build | rg '/out/[^/]+\\.rs$' | head.
- Keep recursive shell searches bounded; Pi enforces a 30-second ceiling so a search cannot stall the agent watchdog.`;

// These roots are deliberately exact. A precise store object such as
// /nix/store/<hash>-package remains inspectable, while fan-out scans of the
// complete Nix store or filesystem are refused before they can start.
const BROAD_FIND_ROOT = /\bfind(?:\s+-[A-Za-z]+)*\s+(?:["']?(?:\/|\/home|\/nix|\/nix\/store|\$HOME|\$\{HOME\}|~)["']?)(?=\s|$|[;&|)])/u;
const BROAD_RG_FILES_ROOT = /\brg\s+--files(?:\s+[^\s;&|]+)*\s+(?:["']?(?:\/|\/home|\/nix|\/nix\/store|\$HOME|\$\{HOME\}|~)["']?)(?=\s|$|[;&|)])/u;
const RECURSIVE_SEARCH = /\bfind\b|\brg\b|\bgrep\s+(?:[^\n;&|]*\s)?-[^\s;&|]*[Rr]/u;

export function unsafeGlobalSearch(command: string): boolean {
	return BROAD_FIND_ROOT.test(command) || BROAD_RG_FILES_ROOT.test(command);
}

export function boundedSearchTimeout(command: string, requested: unknown): number | undefined {
	if (!RECURSIVE_SEARCH.test(command)) {
		return typeof requested === "number" ? requested : undefined;
	}
	if (typeof requested !== "number" || !Number.isFinite(requested) || requested > SEARCH_TIMEOUT_SECONDS) {
		return SEARCH_TIMEOUT_SECONDS;
	}
	return requested;
}

/** Keep repository discovery useful without allowing silent whole-machine scans. */
export function registerBoundedSearch(pi: ExtensionAPI): void {
	pi.on("before_agent_start", (event) => ({
		systemPrompt: `${event.systemPrompt}\n\n${SEARCH_GUIDANCE}`,
	}));

	pi.on("tool_call", (event) => {
		if (event.toolName !== "bash" || typeof event.input !== "object" || event.input === null) return;
		const input = event.input as { command?: unknown; timeout?: unknown };
		if (typeof input.command !== "string") return;

		if (unsafeGlobalSearch(input.command)) {
			return {
				block: true,
				reason: "Whole-machine search blocked: on NixOS it traverses /nix/store and can stall the subagent. Search the repository with Pi find/grep or `rg --files -uu <bounded-root> | rg '<pattern>'`. Generated Rust output normally lives below `rust/target/debug/build`.",
			};
		}

		const timeout = boundedSearchTimeout(input.command, input.timeout);
		if (timeout !== undefined) input.timeout = timeout;
	});
}
