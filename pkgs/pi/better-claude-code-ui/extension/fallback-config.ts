import {
	chmodSync,
	existsSync,
	mkdirSync,
	readFileSync,
	renameSync,
	writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export type FallbackEffort = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";

export interface FallbackProfile {
	model: string;
	effort?: FallbackEffort;
}

export interface FallbackLayer {
	id: string;
	name: string;
	model_profiles: Record<string, FallbackProfile>;
}

export interface GentleFallbackConfig {
	version: 1;
	fallbacks: FallbackLayer[];
}

export interface RuntimeFallbackRoute {
	provider: string;
	model: string;
	label: string;
	thinking?: FallbackEffort;
}

const EFFORTS = new Set<FallbackEffort>([
	"off",
	"minimal",
	"low",
	"medium",
	"high",
	"xhigh",
	"max",
]);

const ROUTE_LABELS: Record<string, string> = {
	"explabs/deepseek-v4.1-flash": "DeepSeek V4.1 Flash",
	"opencode-go/muse-spark-1.3-contributor": "Muse Spark 1.3",
};

// This packaged default is the same JSON consumed by the Nix bootstrap. A
// missing per-user file therefore starts with the declarative A→B→C→D design
// instead of an obsolete compiled fallback list.
const IMPORTED_FALLBACKS = JSON.parse(
	readFileSync(join(dirname(fileURLToPath(import.meta.url)), "fallback-defaults.json"), "utf8"),
) as GentleFallbackConfig;

function cloneConfig(config: GentleFallbackConfig): GentleFallbackConfig {
	return JSON.parse(JSON.stringify(config)) as GentleFallbackConfig;
}

export function fallbackConfigPath(): string {
	const override = process.env.GENTLE_FALLBACK_CONFIG?.trim();
	if (override) return override;
	const agentHome = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
	return join(agentHome, "gentle-fallbacks.json");
}

function normalizedProfile(value: unknown): FallbackProfile | undefined {
	if (!value || typeof value !== "object") return undefined;
	const raw = value as Record<string, unknown>;
	const model = typeof raw.model === "string" ? raw.model.trim() : "";
	if (!model.includes("/") || /[\r\n]/u.test(model)) return undefined;
	const effort = typeof raw.effort === "string" && EFFORTS.has(raw.effort as FallbackEffort)
		? raw.effort as FallbackEffort
		: undefined;
	return effort ? { model, effort } : { model };
}

function normalizedConfig(value: unknown): GentleFallbackConfig | undefined {
	if (!value || typeof value !== "object") return undefined;
	const raw = value as Record<string, unknown>;
	if (raw.version !== 1 || !Array.isArray(raw.fallbacks)) return undefined;
	const fallbacks: FallbackLayer[] = [];
	for (let index = 0; index < raw.fallbacks.length; index++) {
		const candidate = raw.fallbacks[index];
		if (!candidate || typeof candidate !== "object") continue;
		const layer = candidate as Record<string, unknown>;
		const profiles: Record<string, FallbackProfile> = {};
		if (layer.model_profiles && typeof layer.model_profiles === "object") {
			for (const [agent, profile] of Object.entries(layer.model_profiles as Record<string, unknown>)) {
				const normalized = normalizedProfile(profile);
				if (agent.trim() && normalized) profiles[agent] = normalized;
			}
		}
		fallbacks.push({
			id: typeof layer.id === "string" && layer.id.trim() ? layer.id.trim() : `fallback-${index + 1}`,
			name: typeof layer.name === "string" && layer.name.trim() ? layer.name.trim() : `Fallback ${index + 1}`,
			model_profiles: profiles,
		});
	}
	return { version: 1, fallbacks };
}

export function importedFallbackConfig(): GentleFallbackConfig {
	return cloneConfig(IMPORTED_FALLBACKS);
}

export function readFallbackConfig(): GentleFallbackConfig {
	const path = fallbackConfigPath();
	if (!existsSync(path)) return importedFallbackConfig();
	try {
		return normalizedConfig(JSON.parse(readFileSync(path, "utf8"))) ?? importedFallbackConfig();
	} catch {
		return importedFallbackConfig();
	}
}

export function writeFallbackConfig(config: GentleFallbackConfig): GentleFallbackConfig {
	const normalized = normalizedConfig(config);
	if (!normalized) throw new Error("Invalid Gentle fallback configuration");
	const path = fallbackConfigPath();
	mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
	const temporary = `${path}.${process.pid}.${Date.now()}.tmp`;
	writeFileSync(temporary, `${JSON.stringify(normalized, null, 2)}\n`, { mode: 0o600 });
	renameSync(temporary, path);
	chmodSync(path, 0o600);
	return cloneConfig(normalized);
}

export function ensureFallbackConfig(): GentleFallbackConfig {
	const config = readFallbackConfig();
	if (!existsSync(fallbackConfigPath())) writeFallbackConfig(config);
	return config;
}

export function fallbackRoutesForAgent(agentName: string): RuntimeFallbackRoute[] {
	const routes: RuntimeFallbackRoute[] = [];
	for (const layer of readFallbackConfig().fallbacks) {
		const profile = layer.model_profiles[agentName];
		if (!profile) continue;
		const slash = profile.model.indexOf("/");
		if (slash <= 0 || slash === profile.model.length - 1) continue;
		const provider = profile.model.slice(0, slash);
		const model = profile.model.slice(slash + 1);
		routes.push({
			provider,
			model,
			label: ROUTE_LABELS[profile.model] ?? model,
			...(profile.effort ? { thinking: profile.effort } : {}),
		});
	}
	return routes;
}
