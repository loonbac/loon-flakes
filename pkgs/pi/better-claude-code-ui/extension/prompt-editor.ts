/**
 * CC prompt pointer — the `❯ ` at the head of the input box (AUDIT §6 启动
 * Logo/输入框 P1 "输入框缺少 CC 的 ❯ 提示符").
 *
 * We extend pi's CustomEditor (NOT the bare pi-tui Editor — CustomEditor routes
 * app keybindings and extension shortcuts) and preserve its native render as
 * the inside of a wallpaper-palette card. The pointer retains the editor's
 * borderColor, so bash mode and reasoning-level feedback remain visible while
 * the card itself stays consistent with the transcript panels.
 */
import type { ExtensionAPI, KeybindingsManager } from "@earendil-works/pi-coding-agent";
import { CustomEditor } from "@earendil-works/pi-coding-agent";
import type { EditorTheme, TUI, TuiMouseEvent, TuiMouseEventResult } from "@earendil-works/pi-tui";

/** Columns reserved for the pointer: `❯` + one space. */
const PROMPT_COL = 2;
const PANEL_INSET = 2;
const TRANSCRIPT_THEME = Symbol.for("better-cc-ui:transcript-theme");

interface PromptPaletteTheme {
	fg?: (role: string, text: string) => string;
}

interface EditorRenderState {
	renderedVisibleLineCount?: number;
	renderedAutocompleteHeight?: number;
}

function promptTone(role: string, text: string, fallback: (text: string) => string): string {
	try {
		const shared = globalThis as unknown as Record<symbol, unknown>;
		const theme = shared[TRANSCRIPT_THEME] as PromptPaletteTheme | undefined;
		return theme?.fg?.(role, text) ?? fallback(text);
	} catch {
		return fallback(text);
	}
}

export class PromptEditor extends CustomEditor {
	constructor(tui: TUI, theme: EditorTheme, keybindings: KeybindingsManager) {
		super(tui, theme, keybindings, { paddingX: PROMPT_COL });
	}

	/** The host copies the DEFAULT editor's paddingX onto a custom editor right
	 *  after construction (interactive-mode.js:2067); never drop below the
	 *  pointer column or the glyph would overwrite text. */
	override setPaddingX(padding: number): void {
		super.setPaddingX(Math.max(padding, PROMPT_COL));
	}

	override render(width: number): string[] {
		if (width < 16) return super.render(width);

		// Reserve two columns on each side for `│ ` and ` │`. Rendering the
		// native editor at the resulting width preserves its wrapping, cursor,
		// history, paste markers, scrolling, and autocomplete calculations.
		const innerWidth = Math.max(1, width - PANEL_INSET * 2);
		const rows = super.render(innerWidth);
		// rows[0] is the top border; rows[1] is the first content row, which
		// starts with paddingX spaces of left padding. Extremely narrow widths
		// clamp padding below 2 — then skip painting rather than eat a column.
		const first = rows[1];
		if (first !== undefined && first.startsWith("  ")) {
			rows[1] = `${this.borderColor("❯")} ${first.slice(2)}`;
		}

		const state = this as unknown as EditorRenderState;
		const visibleLineCount = Math.max(1, state.renderedVisibleLineCount ?? 1);
		const autocompleteHeight = Math.max(0, state.renderedAutocompleteHeight ?? 0);
		const nativeBottom = Math.min(rows.length - 1, visibleLineCount + 1);
		const border = (text: string) => promptTone("borderAccent", text, this.borderColor);
		const label = (text: string) => promptTone("claudeShimmer", text, this.borderColor);
		const borderWidth = Math.max(1, width - 2);
		const titlePrefix = "─ ";
		const titleSuffix = " ";
		const titleWidth = titlePrefix.length + "loonbac".length + titleSuffix.length;
		const topFill = Math.max(0, borderWidth - titleWidth);
		const framed: string[] = [
			`${border(`┌${titlePrefix}`)}${label("loonbac")}${border(`${titleSuffix}${"─".repeat(topFill)}┐`)}`,
		];

		for (let index = 1; index < nativeBottom; index++) {
			framed.push(`${border("│")} ${rows[index] ?? " ".repeat(innerWidth)} ${border("│")}`);
		}
		framed.push(border(`└${"─".repeat(borderWidth)}┘`));

		// Pi renders autocomplete after the editor's native bottom border. Keep
		// it below the card and indent it by the same two columns. Its row index
		// stays unchanged, which preserves keyboard and mouse selection.
		if (autocompleteHeight > 0) {
			for (let index = nativeBottom + 1; index < rows.length; index++) {
				framed.push(`${" ".repeat(PANEL_INSET)}${rows[index] ?? ""}`);
			}
		}
		return framed;
	}

	override handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
		if (event.width < 16) return super.handleMouse(event);
		// The native editor is rendered two cells inward. Translate clicks and
		// autocomplete hit testing back into its coordinate system.
		return super.handleMouse({
			...event,
			x: event.x - PANEL_INSET,
			width: Math.max(1, event.width - PANEL_INSET * 2),
		});
	}
}

export function registerPromptPointer(pi: ExtensionAPI): void {
	pi.on("session_start", async (_event, ctx) => {
		if (ctx.mode !== "tui") return;
		ctx.ui.setEditorComponent((tui, theme, keybindings) => new PromptEditor(tui, theme, keybindings));
	});
}
