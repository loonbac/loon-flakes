import { isKeyRelease, matchesKey, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import {
	ensureFallbackConfig,
	type FallbackEffort,
	type FallbackLayer,
	type FallbackProfile,
	type GentleFallbackConfig,
	writeFallbackConfig,
} from "./fallback-config.js";

const SET_ALL_AGENTS = "Set all agents";
const PANEL_STATE = Symbol.for("better-cc-ui:gentle-fallback-panel-state-v1");
const PANEL_INPUT_BASE = Symbol.for("better-cc-ui:gentle-fallback-panel-input-base");
const PANEL_RENDER_BASE = Symbol.for("better-cc-ui:gentle-fallback-panel-render-base");
const AGENT_ROWS = 7;
const MODEL_ROWS = 11;
const EFFORTS: FallbackEffort[] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

type View = "primary" | "home" | "agents" | "models" | "effort";

interface Transition {
	startedAt: number;
	duration: number;
}

interface FallbackPanelState {
	view: View;
	config: GentleFallbackConfig;
	layerIndex: number;
	cursor: number;
	modelCursor: number;
	effortCursor: number;
	query: string;
	selectedAgent: string;
	savedAt?: number;
	transition?: Transition;
	animationGeneration: number;
}

interface GentlePanelLike {
	rows: string[];
	modelOptions: string[];
	mode: string;
	cursor?: number;
	selectedRow?: string;
	modelCursor?: number;
	query?: string;
	draft?: Record<string, { model?: string; thinking?: string }>;
	theme?: { fg: (color: string, text: string) => string };
	handleInput: (data: string) => void;
	render: (width: number) => string[];
	[PANEL_STATE]?: FallbackPanelState;
	[PANEL_INPUT_BASE]?: (data: string) => void;
	[PANEL_RENDER_BASE]?: (width: number) => string[];
}

interface TuiLike {
	requestRender?: () => void;
}

function cloneConfig(config: GentleFallbackConfig): GentleFallbackConfig {
	return JSON.parse(JSON.stringify(config)) as GentleFallbackConfig;
}

function isGentleModelsPanel(component: unknown): component is GentlePanelLike {
	if (!component || typeof component !== "object") return false;
	const panel = component as Partial<GentlePanelLike>;
	return Array.isArray(panel.rows)
		&& panel.rows[0] === SET_ALL_AGENTS
		&& Array.isArray(panel.modelOptions)
		&& typeof panel.handleInput === "function"
		&& typeof panel.render === "function";
}

function tone(panel: GentlePanelLike, color: string, text: string): string {
	return panel.theme?.fg ? panel.theme.fg(color, text) : text;
}

function selected(panel: GentlePanelLike, text: string): string {
	return `\x1b[4m${tone(panel, "thinkingHigh", text)}\x1b[24m`;
}

function fit(line: string, width: number): string {
	const current = visibleWidth(line);
	if (current > width) return truncateToWidth(line, Math.max(1, width), "…", true);
	return `${line}${" ".repeat(Math.max(0, width - current))}`;
}

function card(panel: GentlePanelLike, lines: string[], width: number): string[] {
	const innerWidth = Math.max(1, width - 4);
	const horizontal = "─".repeat(innerWidth + 2);
	const border = (text: string) => tone(panel, "border", text);
	return [
		border(`╭${horizontal}╮`),
		...lines.map((line) => `${border("│")} ${fit(line, innerWidth)} ${border("│")}`),
		border(`╰${horizontal}╯`),
	];
}

function centered(line: string, width: number): string {
	const padding = Math.max(0, Math.floor((width - visibleWidth(line)) / 2));
	return `${" ".repeat(padding)}${line}`;
}

function layerProfiles(layer: FallbackLayer): Record<string, FallbackProfile> {
	return layer.model_profiles;
}

function startTransition(state: FallbackPanelState, tui: TuiLike): void {
	state.transition = { startedAt: Date.now(), duration: 150 };
	const generation = ++state.animationGeneration;
	for (const delay of [0, 30, 60, 90, 120, 155]) {
		setTimeout(() => {
			if (state.animationGeneration !== generation) return;
			if (delay >= 155) state.transition = undefined;
			tui.requestRender?.();
		}, delay);
	}
}

function slideIn(lines: string[], width: number, transition: Transition | undefined): string[] {
	if (!transition) return lines;
	const progress = Math.min(1, Math.max(0, (Date.now() - transition.startedAt) / transition.duration));
	const offset = Math.round((1 - progress) * Math.max(0, width - 2));
	if (offset <= 0) return lines;
	const prefix = " ".repeat(offset);
	return lines.map((line) => truncateToWidth(`${prefix}${line}`, width, "", true));
}

function newLayer(config: GentleFallbackConfig): FallbackLayer {
	const ordinal = config.fallbacks.length + 1;
	let name = `Fallback ${ordinal}`;
	let suffix = ordinal;
	const names = new Set(config.fallbacks.map((layer) => layer.name));
	while (names.has(name)) name = `Fallback ${++suffix}`;
	return {
		id: `fallback-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
		name,
		model_profiles: {},
	};
}

function currentLayer(state: FallbackPanelState): FallbackLayer | undefined {
	return state.config.fallbacks[state.layerIndex];
}

function save(state: FallbackPanelState): void {
	state.config = writeFallbackConfig(state.config);
	state.savedAt = Date.now();
}

function renderTabs(panel: GentlePanelLike, active: "models" | "fallbacks", width: number): string {
	const models = active === "models" ? selected(panel, "Modelos") : tone(panel, "muted", "Modelos");
	const fallbacks = active === "fallbacks" ? selected(panel, "Fallbacks") : tone(panel, "muted", "Fallbacks");
	return centered(`${models}${tone(panel, "muted", "   Tab   ")}${fallbacks}`, width);
}

function renderHome(panel: GentlePanelLike, state: FallbackPanelState, width: number): string[] {
	const innerWidth = Math.max(1, width - 4);
	const lines: string[] = [
		renderTabs(panel, "fallbacks", innerWidth),
		"",
		"",
		"",
		"",
	];
	const createLabel = "＋ Crear nuevo fallback";
	lines.push(centered(
		`${tone(panel, "accent", "▸")} ${selected(panel, createLabel)}`,
		innerWidth,
	));
	lines.push("", "", "");
	if (state.savedAt && Date.now() - state.savedAt < 2500) {
		lines.push(centered(tone(panel, "success", "✓ Fallbacks guardados"), innerWidth));
		lines.push("");
	}
	const count = state.config.fallbacks.length;
	lines.push(centered(tone(panel, "muted", `${count} fallback${count === 1 ? "" : "s"} creado${count === 1 ? "" : "s"} · Shift+Tab editar el anterior`), innerWidth));
	lines.push(centered(tone(panel, "muted", "Enter crear · Tab volver a modelos"), innerWidth));
	return card(panel, lines, width);
}

function profileSummary(layer: FallbackLayer, rows: string[]): { model: string; effort: string } {
	const profiles = rows.slice(1).map((agent) => layer.model_profiles[agent]);
	const models = profiles.map((profile) => profile?.model ?? "—");
	const efforts = profiles.map((profile) => profile?.effort ?? "—");
	const firstModel = models[0] ?? "—";
	const firstEffort = efforts[0] ?? "—";
	return {
		model: models.every((model) => model === firstModel) ? firstModel : "mixed",
		effort: efforts.every((effort) => effort === firstEffort) ? firstEffort : "mixed",
	};
}

function assignmentValues(panel: GentlePanelLike, state: FallbackPanelState, row: string): { model: string; effort: string } {
	const layer = currentLayer(state)!;
	const profile = row === SET_ALL_AGENTS ? undefined : layerProfiles(layer)[row];
	const summary = row === SET_ALL_AGENTS ? profileSummary(layer, panel.rows) : undefined;
	return {
		model: summary?.model ?? profile?.model ?? "—",
		effort: summary?.effort ?? profile?.effort ?? "—",
	};
}

function compactAssignmentLabel(
	panel: GentlePanelLike,
	row: string,
	values: { model: string; effort: string },
	agentWidth: number,
): string {
	return `${tone(panel, "text", row.padEnd(agentWidth))}  ${tone(panel, "thinkingHigh", values.model)}${tone(panel, "muted", " · ")}${tone(panel, "thinkingHigh", values.effort)}`;
}

function renderAgentGrid(
	panel: GentlePanelLike,
	labels: string[],
	cursor: number,
	innerWidth: number,
): { lines: string[]; twoColumns: boolean } {
	const gapWidth = 4;
	const leftWidth = Math.max(0, ...labels.filter((_label, index) => index % 2 === 0).map(visibleWidth));
	const rightWidth = Math.max(0, ...labels.filter((_label, index) => index % 2 === 1).map(visibleWidth));
	const twoColumns = labels.length > 1 && 2 + leftWidth + gapWidth + 2 + rightWidth <= innerWidth;
	const columns = twoColumns ? 2 : 1;
	const pageSize = AGENT_ROWS * columns;
	const listCursor = Math.min(cursor, Math.max(0, labels.length - 1));
	const start = Math.floor(listCursor / pageSize) * pageSize;
	const end = Math.min(labels.length, start + pageSize);
	const lines: string[] = [];
	if (start > 0) lines.push(tone(panel, "muted", `  ↑ ${start} subagente(s)`));
	for (let row = 0; row < AGENT_ROWS; row++) {
		const leftIndex = start + row * columns;
		if (leftIndex >= end) break;
		const cell = (index: number, width: number): string => {
			const focused = index === cursor;
			const label = focused ? `\x1b[4m${labels[index]}\x1b[24m` : labels[index]!;
			return `${focused ? tone(panel, "accent", "▸") : " "} ${label}${" ".repeat(Math.max(0, width - visibleWidth(labels[index]!)))}`;
		};
		const left = cell(leftIndex, twoColumns ? leftWidth : visibleWidth(labels[leftIndex]!));
		if (!twoColumns) {
			lines.push(left);
			continue;
		}
		const rightIndex = leftIndex + 1;
		const right = rightIndex < end ? cell(rightIndex, rightWidth) : "";
		lines.push(`${left}${" ".repeat(gapWidth)}${right}`);
	}
	if (end < labels.length) lines.push(tone(panel, "muted", `  ↓ ${labels.length - end} subagente(s)`));
	return { lines, twoColumns };
}

function primaryAssignmentValues(panel: GentlePanelLike, row: string): { model: string; effort: string } {
	const profiles = panel.draft ?? {};
	if (row !== SET_ALL_AGENTS) {
		return {
			model: profiles[row]?.model ?? "inherit",
			effort: profiles[row]?.thinking ?? "inherit",
		};
	}
	const assignments = panel.rows.slice(1).map((agent) => ({
		model: profiles[agent]?.model ?? "inherit",
		effort: profiles[agent]?.thinking ?? "inherit",
	}));
	const first = assignments[0] ?? { model: "inherit", effort: "inherit" };
	return {
		model: assignments.every((value) => value.model === first.model) ? first.model : "mixed",
		effort: assignments.every((value) => value.effort === first.effort) ? first.effort : "mixed",
	};
}

function renderPrimaryAgents(panel: GentlePanelLike, width: number): string[] {
	const innerWidth = Math.max(1, width - 4);
	const cursor = panel.cursor ?? 0;
	const agentWidth = Math.max(...panel.rows.map((row) => visibleWidth(row)));
	const labels = panel.rows.map((row) => compactAssignmentLabel(panel, row, primaryAssignmentValues(panel, row), agentWidth));
	const grid = renderAgentGrid(panel, labels, cursor, innerWidth);
	const lines: string[] = [
		tone(panel, "accent", "Assign Models and Effort to Agents"),
		"",
		tone(panel, "muted", "Current assignments:"),
		"",
		...grid.lines,
		"",
	];
	const continueFocused = cursor === panel.rows.length;
	lines.push(`${continueFocused ? tone(panel, "accent", "▸") : " "} ${continueFocused ? selected(panel, "Continue") : tone(panel, "text", "Continue")}`);
	const backFocused = cursor === panel.rows.length + 1;
	lines.push(`${backFocused ? tone(panel, "accent", "▸") : " "} ${backFocused ? selected(panel, "← Back") : tone(panel, "text", "← Back")}`);
	lines.push("");
	lines.push(tone(panel, "muted", grid.twoColumns
		? "↑/↓ row · ←/→ column · j/k next/previous · Enter model/save · e effort · i inherit"
		: "j/k scroll · Enter model/save · e effort · i inherit"));
	lines.push(tone(panel, "muted", "c custom · x export · r restore · Ctrl+S save · Tab fallbacks · Esc back"));
	return card(panel, lines, width);
}

function renderAgents(panel: GentlePanelLike, state: FallbackPanelState, width: number): string[] {
	const layer = currentLayer(state);
	if (!layer) {
		state.view = "home";
		return renderHome(panel, state, width);
	}
	const innerWidth = Math.max(1, width - 4);
	const lines: string[] = [
		tone(panel, "accent", `${layer.name} · asignar modelos y esfuerzo`),
		"",
		tone(panel, "muted", "Asignaciones de fallback:"),
		"",
	];
	const agentWidth = Math.max(...panel.rows.map((row) => visibleWidth(row)));
	const labels = panel.rows.map((row) => compactAssignmentLabel(panel, row, assignmentValues(panel, state, row), agentWidth));
	const grid = renderAgentGrid(panel, labels, state.cursor, innerWidth);
	lines.push(...grid.lines);
	lines.push("");
	const continueFocused = state.cursor === panel.rows.length;
	lines.push(`${continueFocused ? tone(panel, "accent", "▸") : " "} ${continueFocused ? selected(panel, "Guardar y continuar") : tone(panel, "text", "Guardar y continuar")}`);
	const backFocused = state.cursor === panel.rows.length + 1;
	lines.push(`${backFocused ? tone(panel, "accent", "▸") : " "} ${backFocused ? selected(panel, "← Volver") : tone(panel, "text", "← Volver")}`);
	lines.push("");
	lines.push(tone(panel, "muted", grid.twoColumns
		? "↑/↓ fila · ←/→ columna · j/k siguiente/anterior · Enter modelo/guardar · e esfuerzo · i vaciar"
		: "j/k navegar · Enter modelo/guardar · e esfuerzo · i vaciar · Ctrl+S guardar"));
	lines.push(tone(panel, "muted", "Shift+Tab fallback anterior · Tab crear otro · Esc modelos"));
	return card(panel, lines, width);
}

function availableModels(panel: GentlePanelLike, state: FallbackPanelState): string[] {
	// Gentle prepends control choices such as "Inherit active/default model";
	// accepting merely any slash would accidentally expose that sentence as a
	// provider route. Real registry identifiers are single-token provider/model.
	const models = panel.modelOptions.filter((option) => /^[A-Za-z0-9._~:@+%-]+\/[A-Za-z0-9._~:@/+%-]+$/u.test(option));
	const query = state.query.trim().toLowerCase();
	return query ? models.filter((model) => model.toLowerCase().includes(query)) : models;
}

function modelGrid(
	panel: GentlePanelLike,
	options: string[],
	cursor: number,
	innerWidth: number,
): { lines: string[]; twoColumns: boolean } {
	const gapWidth = 4;
	const allLeft = options.filter((_option, index) => index % 2 === 0);
	const allRight = options.filter((_option, index) => index % 2 === 1);
	const leftLabelWidth = Math.max(0, ...allLeft.map((option) => visibleWidth(option)));
	const rightLabelWidth = Math.max(0, ...allRight.map((option) => visibleWidth(option)));
	const requiredWidth = 2 + leftLabelWidth + gapWidth + 2 + rightLabelWidth;
	const twoColumns = allRight.length > 0 && requiredWidth <= innerWidth;
	const columnCount = twoColumns ? 2 : 1;
	const pageSize = MODEL_ROWS * columnCount;
	const start = Math.floor(cursor / pageSize) * pageSize;
	const end = Math.min(options.length, start + pageSize);
	const renderCell = (option: string, index: number, labelWidth: number): string => {
		const focused = index === cursor;
		const label = focused ? selected(panel, option) : tone(panel, "text", option);
		return `${focused ? tone(panel, "accent", "▸") : " "} ${label}${" ".repeat(Math.max(0, labelWidth - visibleWidth(option)))}`;
	};
	const lines: string[] = [];
	for (let row = 0; row < MODEL_ROWS; row++) {
		const leftIndex = start + row * columnCount;
		if (leftIndex >= end) break;
		const left = renderCell(options[leftIndex]!, leftIndex, twoColumns ? leftLabelWidth : visibleWidth(options[leftIndex]!));
		if (!twoColumns) {
			lines.push(left);
			continue;
		}
		const rightIndex = leftIndex + 1;
		const right = rightIndex < end
			? renderCell(options[rightIndex]!, rightIndex, rightLabelWidth)
			: "";
		lines.push(`${left}${" ".repeat(gapWidth)}${right}`);
	}
	return { lines, twoColumns };
}

function primaryModelOptions(panel: GentlePanelLike): string[] {
	const query = (panel.query ?? "").trim().toLowerCase();
	return query
		? panel.modelOptions.filter((option) => option.toLowerCase().includes(query))
		: panel.modelOptions;
}

function renderPrimaryModels(panel: GentlePanelLike, width: number): string[] {
	const innerWidth = Math.max(1, width - 4);
	const options = primaryModelOptions(panel);
	const cursor = Math.min(Math.max(0, panel.modelCursor ?? 0), Math.max(0, options.length - 1));
	const grid = modelGrid(panel, options, cursor, innerWidth);
	const lines: string[] = [
		tone(panel, "accent", `Select model for ${panel.selectedRow ?? SET_ALL_AGENTS}`),
		"",
		`${tone(panel, "accent", "◎")} ${tone(panel, "muted", panel.query || "search...")}`,
		"",
		...grid.lines,
	];
	if (options.length === 0) lines.push(tone(panel, "muted", "  No matching models"));
	lines.push("");
	lines.push(tone(panel, "muted", grid.twoColumns
		? "↑/↓ row · ←/→ column · j/k next/previous · type search · Enter select · Esc back"
		: "j/k navigate · type search · Enter select · Esc back"));
	return card(panel, lines, width);
}

function renderModels(panel: GentlePanelLike, state: FallbackPanelState, width: number): string[] {
	const innerWidth = Math.max(1, width - 4);
	const options = availableModels(panel, state);
	const lines: string[] = [
		tone(panel, "accent", `Seleccionar modelo para ${state.selectedAgent}`),
		"",
		`${tone(panel, "accent", "◎")} ${tone(panel, "muted", state.query || "buscar...")}`,
		"",
	];
	const grid = modelGrid(panel, options, state.modelCursor, innerWidth);
	lines.push(...grid.lines);
	if (options.length === 0) lines.push(tone(panel, "muted", "  No hay modelos coincidentes"));
	lines.push("");
	lines.push(tone(panel, "muted", grid.twoColumns
		? "↑/↓ fila · ←/→ columna · j/k siguiente/anterior · escribir buscar · Enter seleccionar · Esc volver"
		: "j/k navegar · escribir para buscar · Enter seleccionar · Esc volver"));
	return card(panel, lines, width);
}

function renderEffort(panel: GentlePanelLike, state: FallbackPanelState, width: number): string[] {
	const lines: string[] = [
		tone(panel, "accent", `Seleccionar esfuerzo para ${state.selectedAgent}`),
		"",
	];
	for (let index = 0; index < EFFORTS.length; index++) {
		const focused = index === state.effortCursor;
		const label = EFFORTS[index]!;
		lines.push(`${focused ? tone(panel, "accent", "▸") : " "} ${focused ? selected(panel, label) : tone(panel, "text", label)}`);
	}
	lines.push("");
	lines.push(tone(panel, "muted", "j/k navegar · Enter seleccionar · Esc volver"));
	return card(panel, lines, width);
}

function applyModel(panel: GentlePanelLike, state: FallbackPanelState, model: string): void {
	const layer = currentLayer(state);
	if (!layer) return;
	const agents = state.selectedAgent === SET_ALL_AGENTS ? panel.rows.slice(1) : [state.selectedAgent];
	for (const agent of agents) {
		const previous = layer.model_profiles[agent];
		layer.model_profiles[agent] = { model, ...(previous?.effort ? { effort: previous.effort } : {}) };
	}
}

function applyEffort(panel: GentlePanelLike, state: FallbackPanelState, effort: FallbackEffort): void {
	const layer = currentLayer(state);
	if (!layer) return;
	const agents = state.selectedAgent === SET_ALL_AGENTS ? panel.rows.slice(1) : [state.selectedAgent];
	for (const agent of agents) {
		const previous = layer.model_profiles[agent];
		if (previous?.model) layer.model_profiles[agent] = { model: previous.model, effort };
	}
}

function clearAssignment(panel: GentlePanelLike, state: FallbackPanelState): void {
	const layer = currentLayer(state);
	if (!layer) return;
	const row = panel.rows[state.cursor];
	if (row === SET_ALL_AGENTS) layer.model_profiles = {};
	else if (row) delete layer.model_profiles[row];
}

function handleHome(_panel: GentlePanelLike, state: FallbackPanelState, data: string, tui: TuiLike): void {
	if (matchesKey(data, "shift+tab") && state.config.fallbacks.length > 0) {
		state.layerIndex = state.config.fallbacks.length - 1;
		state.cursor = 0;
		state.view = "agents";
		startTransition(state, tui);
		return;
	}
	if (matchesKey(data, "tab") || matchesKey(data, "escape")) {
		state.view = "primary";
		startTransition(state, tui);
		return;
	}
	if (matchesKey(data, "ctrl+s")) {
		save(state);
		return;
	}
	if (!matchesKey(data, "return")) return;
	state.config.fallbacks.push(newLayer(state.config));
	state.layerIndex = state.config.fallbacks.length - 1;
	state.cursor = 0;
	state.view = "agents";
	startTransition(state, tui);
}

function handleAgents(panel: GentlePanelLike, state: FallbackPanelState, data: string, tui: TuiLike): void {
	const maxCursor = panel.rows.length + 1;
	if (matchesKey(data, "shift+tab")) {
		if (state.layerIndex > 0) {
			state.layerIndex--;
			state.cursor = 0;
		} else {
			state.view = "primary";
		}
		startTransition(state, tui);
		return;
	}
	if (matchesKey(data, "tab")) {
		if (state.layerIndex + 1 < state.config.fallbacks.length) {
			state.layerIndex++;
			state.cursor = 0;
		} else {
			state.view = "home";
		}
		startTransition(state, tui);
		return;
	}
	if (matchesKey(data, "escape")) {
		state.view = "primary";
		return;
	}
	if (matchesKey(data, "ctrl+s")) {
		save(state);
		return;
	}
	if (matchesKey(data, "down")) {
		state.cursor = state.cursor < panel.rows.length
			? (state.cursor + 2 < panel.rows.length ? state.cursor + 2 : panel.rows.length)
			: Math.min(maxCursor, state.cursor + 1);
		return;
	}
	if (matchesKey(data, "up")) {
		state.cursor = state.cursor < panel.rows.length
			? Math.max(0, state.cursor - 2)
			: (state.cursor === panel.rows.length ? Math.max(0, panel.rows.length - 2) : state.cursor - 1);
		return;
	}
	if (matchesKey(data, "right")) {
		if (state.cursor < panel.rows.length && state.cursor % 2 === 0) {
			state.cursor = Math.min(panel.rows.length - 1, state.cursor + 1);
		}
		return;
	}
	if (matchesKey(data, "left")) {
		if (state.cursor < panel.rows.length && state.cursor % 2 === 1) state.cursor--;
		return;
	}
	if (matchesKey(data, "j")) {
		state.cursor = Math.min(maxCursor, state.cursor + 1);
		return;
	}
	if (matchesKey(data, "k")) {
		state.cursor = Math.max(0, state.cursor - 1);
		return;
	}
	if (matchesKey(data, "i")) {
		clearAssignment(panel, state);
		return;
	}
	if (matchesKey(data, "e")) {
		const row = panel.rows[state.cursor];
		if (!row) return;
		state.selectedAgent = row;
		state.effortCursor = 0;
		state.view = "effort";
		return;
	}
	if (!matchesKey(data, "return")) return;
	if (state.cursor === panel.rows.length) {
		save(state);
		state.view = "home";
		startTransition(state, tui);
		return;
	}
	if (state.cursor === panel.rows.length + 1) {
		state.view = "primary";
		return;
	}
	const row = panel.rows[state.cursor];
	if (!row) return;
	state.selectedAgent = row;
	state.modelCursor = 0;
	state.query = "";
	state.view = "models";
}

function handleModels(panel: GentlePanelLike, state: FallbackPanelState, data: string): void {
	const options = availableModels(panel, state);
	if (matchesKey(data, "escape")) {
		state.view = "agents";
		state.query = "";
		return;
	}
	if (matchesKey(data, "backspace")) {
		state.query = state.query.slice(0, -1);
		state.modelCursor = Math.min(state.modelCursor, Math.max(0, availableModels(panel, state).length - 1));
		return;
	}
	if (matchesKey(data, "down")) {
		state.modelCursor = Math.min(Math.max(0, options.length - 1), state.modelCursor + 2);
		return;
	}
	if (matchesKey(data, "up")) {
		state.modelCursor = Math.max(0, state.modelCursor - 2);
		return;
	}
	if (matchesKey(data, "right")) {
		if (state.modelCursor % 2 === 0) {
			state.modelCursor = Math.min(Math.max(0, options.length - 1), state.modelCursor + 1);
		}
		return;
	}
	if (matchesKey(data, "left")) {
		if (state.modelCursor % 2 === 1) state.modelCursor--;
		return;
	}
	if (matchesKey(data, "j")) {
		state.modelCursor = Math.min(Math.max(0, options.length - 1), state.modelCursor + 1);
		return;
	}
	if (matchesKey(data, "k")) {
		state.modelCursor = Math.max(0, state.modelCursor - 1);
		return;
	}
	if (matchesKey(data, "return")) {
		const model = options[state.modelCursor];
		if (model) applyModel(panel, state, model);
		state.view = "agents";
		return;
	}
	if (data.length === 1 && data.charCodeAt(0) >= 32) {
		state.query += data;
		state.modelCursor = 0;
	}
}

function handleEffort(panel: GentlePanelLike, state: FallbackPanelState, data: string): void {
	if (matchesKey(data, "escape")) {
		state.view = "agents";
		return;
	}
	if (matchesKey(data, "down") || matchesKey(data, "j")) {
		state.effortCursor = Math.min(EFFORTS.length - 1, state.effortCursor + 1);
		return;
	}
	if (matchesKey(data, "up") || matchesKey(data, "k")) {
		state.effortCursor = Math.max(0, state.effortCursor - 1);
		return;
	}
	if (!matchesKey(data, "return")) return;
	applyEffort(panel, state, EFFORTS[state.effortCursor]!);
	state.view = "agents";
}

export function installFallbackPanelBehavior(component: unknown, tui: TuiLike): void {
	if (!isGentleModelsPanel(component)) return;
	const panel = component;
	if (panel[PANEL_STATE]) return;
	const config = cloneConfig(ensureFallbackConfig());
	const state: FallbackPanelState = {
		view: "primary",
		config,
		layerIndex: 0,
		cursor: 0,
		modelCursor: 0,
		effortCursor: 0,
		query: "",
		selectedAgent: SET_ALL_AGENTS,
		animationGeneration: 0,
	};
	panel[PANEL_STATE] = state;

	const originalInput = panel.handleInput.bind(panel);
	const originalRender = panel.render.bind(panel);
	panel[PANEL_INPUT_BASE] = originalInput;
	panel[PANEL_RENDER_BASE] = originalRender;

	panel.handleInput = (data: string): void => {
		if (isKeyRelease(data)) return;
		if (state.view === "primary") {
			if (panel.mode === "models" && typeof panel.modelCursor === "number") {
				const options = primaryModelOptions(panel);
				if (matchesKey(data, "down")) {
					panel.modelCursor = Math.min(Math.max(0, options.length - 1), panel.modelCursor + 2);
					return;
				}
				if (matchesKey(data, "up")) {
					panel.modelCursor = Math.max(0, panel.modelCursor - 2);
					return;
				}
				if (matchesKey(data, "right")) {
					if (panel.modelCursor % 2 === 0) {
						panel.modelCursor = Math.min(Math.max(0, options.length - 1), panel.modelCursor + 1);
					}
					return;
				}
				if (matchesKey(data, "left")) {
					if (panel.modelCursor % 2 === 1) panel.modelCursor--;
					return;
				}
			}
			if (panel.mode === "agents" && matchesKey(data, "shift+tab")) {
				state.config = cloneConfig(ensureFallbackConfig());
				if (state.config.fallbacks.length > 0) {
					state.layerIndex = state.config.fallbacks.length - 1;
					state.cursor = 0;
					state.view = "agents";
					startTransition(state, tui);
					return;
				}
			}
			if (panel.mode === "agents" && matchesKey(data, "tab")) {
				state.config = cloneConfig(ensureFallbackConfig());
				if (state.config.fallbacks.length > 0) {
					state.layerIndex = 0;
					state.cursor = 0;
					state.view = "agents";
				} else {
					state.view = "home";
				}
				startTransition(state, tui);
				return;
			}
			if (panel.mode === "agents" && typeof panel.cursor === "number") {
				const maxCursor = panel.rows.length + 1;
				if (matchesKey(data, "down")) {
					panel.cursor = panel.cursor < panel.rows.length
						? (panel.cursor + 2 < panel.rows.length ? panel.cursor + 2 : panel.rows.length)
						: Math.min(maxCursor, panel.cursor + 1);
					return;
				}
				if (matchesKey(data, "up")) {
					panel.cursor = panel.cursor < panel.rows.length
						? Math.max(0, panel.cursor - 2)
						: (panel.cursor === panel.rows.length ? Math.max(0, panel.rows.length - 2) : panel.cursor - 1);
					return;
				}
				if (matchesKey(data, "right")) {
					if (panel.cursor < panel.rows.length && panel.cursor % 2 === 0) {
						panel.cursor = Math.min(panel.rows.length - 1, panel.cursor + 1);
					}
					return;
				}
				if (matchesKey(data, "left")) {
					if (panel.cursor < panel.rows.length && panel.cursor % 2 === 1) panel.cursor--;
					return;
				}
			}
			originalInput(data);
			return;
		}
		if (state.view === "home") handleHome(panel, state, data, tui);
		else if (state.view === "agents") handleAgents(panel, state, data, tui);
		else if (state.view === "models") handleModels(panel, state, data);
		else if (state.view === "effort") handleEffort(panel, state, data);
	};

	panel.render = (width: number): string[] => {
		let lines: string[];
		if (state.view === "primary") {
			lines = panel.mode === "models"
				? renderPrimaryModels(panel, width)
				: panel.mode === "agents"
					? renderPrimaryAgents(panel, width)
					: originalRender(width);
		}
		else if (state.view === "home") lines = renderHome(panel, state, width);
		else if (state.view === "agents") lines = renderAgents(panel, state, width);
		else if (state.view === "models") lines = renderModels(panel, state, width);
		else lines = renderEffort(panel, state, width);
		return slideIn(lines, width, state.transition);
	};
}
