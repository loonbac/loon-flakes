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
	/** Stable key in gentle-pi's ~/.pi/gentle-ai/profiles.json store. */
	profile?: string;
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

const GENTLE_PROFILES_KIND = "gentle-pi.agent_model_profiles";
const GENTLE_PROFILES_VERSION = 1;
const PRIMARY_PROFILE_NAME = "current";
const PROFILE_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/u;
const RESERVED_PROFILE_NAMES = new Set(["__proto__", "constructor", "prototype"]);

interface GentleProfileEntry {
	model?: string;
	thinking?: FallbackEffort;
}

type GentleProfile = Record<string, GentleProfileEntry>;

interface GentleProfilesFile {
	kind: typeof GENTLE_PROFILES_KIND;
	version: typeof GENTLE_PROFILES_VERSION;
	active?: string;
	profiles: Record<string, GentleProfile>;
}

type GentleProfilesReadResult =
	| { status: "missing" }
	| { status: "invalid" }
	| { status: "valid"; file: GentleProfilesFile };

const ROUTE_LABELS: Record<string, string> = {
	"explabs/deepseek-v4.1-flash": "DeepSeek V4.1 Flash",
	"commandcode/meta/muse-spark-1.3-contributor": "Muse Spark 1.3 Contributor",
	"commandcode/xiaomi/mimo-v2.6-flash": "MiMo V2.6 Flash",
	"commandcode/xiaomi/mimo-v2.6-pro": "MiMo V2.6 Pro",
	"commandcode/stealth/space-bunny-alpha": "Space Bunny Alpha",
};

// This packaged default is the same JSON consumed by the Nix bootstrap. A
// missing per-user file therefore starts with the declarative A→B→C→D design
// instead of an obsolete compiled fallback list.
const IMPORTED_FALLBACKS = JSON.parse(
	readFileSync(join(dirname(fileURLToPath(import.meta.url)), "fallback-defaults.json"), "utf8"),
) as GentleFallbackConfig;
const DECLARATIVE_PROFILE_NAMES = new Set(
	IMPORTED_FALLBACKS.fallbacks
		.map((layer) => layer.profile)
		.filter((profile): profile is string => isValidProfileName(profile)),
);

function cloneConfig(config: GentleFallbackConfig): GentleFallbackConfig {
	return JSON.parse(JSON.stringify(config)) as GentleFallbackConfig;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isValidProfileName(value: unknown): value is string {
	return typeof value === "string"
		&& PROFILE_NAME_PATTERN.test(value)
		&& !RESERVED_PROFILE_NAMES.has(value);
}

function atomicWriteJson(path: string, value: unknown, mode = 0o600): void {
	mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
	const temporary = `${path}.${process.pid}.${Date.now()}.tmp`;
	writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode });
	renameSync(temporary, path);
	chmodSync(path, mode);
}

export function fallbackConfigPath(): string {
	const override = process.env.GENTLE_FALLBACK_CONFIG?.trim();
	if (override) return override;
	const agentHome = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
	return join(agentHome, "gentle-fallbacks.json");
}

export function gentleProfilesPath(): string {
	const configHome = process.env.GENTLE_PI_CONFIG_HOME?.trim()
		|| join(homedir(), ".pi", "gentle-ai");
	return join(configHome, "profiles.json");
}

function gentleModelsPath(): string {
	return join(dirname(gentleProfilesPath()), "models.json");
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
			...(isValidProfileName(layer.profile) ? { profile: layer.profile } : {}),
			model_profiles: profiles,
		});
	}
	return { version: 1, fallbacks };
}

export function importedFallbackConfig(): GentleFallbackConfig {
	return cloneConfig(IMPORTED_FALLBACKS);
}

function normalizedGentleProfile(value: unknown): GentleProfile | undefined {
	if (!isRecord(value)) return undefined;
	const profile: GentleProfile = {};
	for (const [agent, rawEntry] of Object.entries(value)) {
		if (!isRecord(rawEntry)) continue;
		const model = typeof rawEntry.model === "string" ? rawEntry.model.trim() : undefined;
		const thinking = typeof rawEntry.thinking === "string"
			&& EFFORTS.has(rawEntry.thinking as FallbackEffort)
			? rawEntry.thinking as FallbackEffort
			: undefined;
		if (model === undefined && thinking === undefined) {
			profile[agent] = {};
			continue;
		}
		profile[agent] = {
			...(model ? { model } : {}),
			...(thinking ? { thinking } : {}),
		};
	}
	return profile;
}

function readGentleProfiles(): GentleProfilesReadResult {
	const path = gentleProfilesPath();
	if (!existsSync(path)) return { status: "missing" };
	try {
		const raw = JSON.parse(readFileSync(path, "utf8")) as unknown;
		if (!isRecord(raw)
			|| raw.kind !== GENTLE_PROFILES_KIND
			|| raw.version !== GENTLE_PROFILES_VERSION
			|| !isRecord(raw.profiles)) return { status: "invalid" };
		const profiles: Record<string, GentleProfile> = {};
		for (const [name, value] of Object.entries(raw.profiles)) {
			const profile = normalizedGentleProfile(value);
			if (isValidProfileName(name) && profile) profiles[name] = profile;
		}
		const active = isValidProfileName(raw.active) && Object.hasOwn(profiles, raw.active)
			? raw.active
			: undefined;
		return {
			status: "valid",
			file: {
				kind: GENTLE_PROFILES_KIND,
				version: GENTLE_PROFILES_VERSION,
				...(active ? { active } : {}),
				profiles,
			},
		};
	} catch {
		return { status: "invalid" };
	}
}

function readCurrentGentleModelConfig(): GentleProfile {
	try {
		return normalizedGentleProfile(JSON.parse(readFileSync(gentleModelsPath(), "utf8"))) ?? {};
	} catch {
		return {};
	}
}

function bootstrapGentleProfiles(): GentleProfilesFile {
	const current = readCurrentGentleModelConfig();
	return {
		kind: GENTLE_PROFILES_KIND,
		version: GENTLE_PROFILES_VERSION,
		...(Object.keys(current).length > 0 ? { active: PRIMARY_PROFILE_NAME } : {}),
		profiles: { [PRIMARY_PROFILE_NAME]: current },
	};
}

function fallbackProfilesFromGentle(profile: GentleProfile): Record<string, FallbackProfile> {
	const profiles: Record<string, FallbackProfile> = {};
	for (const [agent, entry] of Object.entries(profile)) {
		if (agent === "orchestrator" || !entry.model?.includes("/")) continue;
		profiles[agent] = {
			model: entry.model,
			...(entry.thinking ? { effort: entry.thinking } : {}),
		};
	}
	return profiles;
}

function gentleProfileFromFallback(
	profiles: Record<string, FallbackProfile>,
	previous: GentleProfile = {},
): GentleProfile {
	const next: GentleProfile = {};
	// A fallback panel does not edit the orchestrator, so keep that profile-only
	// routing entry intact when the same profile is updated from /gentle:models.
	if (previous.orchestrator) next.orchestrator = { ...previous.orchestrator };
	for (const [agent, profile] of Object.entries(profiles)) {
		next[agent] = {
			model: profile.model,
			...(profile.effort ? { thinking: profile.effort } : {}),
		};
	}
	return next;
}

function profileNameBase(label: string): string {
	const normalized = label
		.normalize("NFKD")
		.replace(/[\u0300-\u036f]/gu, "")
		.replace(/[^A-Za-z0-9._-]+/gu, "-")
		.replace(/^[._-]+|[._-]+$/gu, "")
		.slice(0, 64);
	return isValidProfileName(normalized) && normalized !== PRIMARY_PROFILE_NAME
		? normalized
		: "fallback";
}

function assignProfileName(layer: FallbackLayer, assigned: Set<string>): string {
	if (isValidProfileName(layer.profile) && !assigned.has(layer.profile)) {
		assigned.add(layer.profile);
		return layer.profile;
	}
	const base = profileNameBase(layer.name);
	let candidate = base;
	let suffix = 2;
	while (assigned.has(candidate) || candidate === PRIMARY_PROFILE_NAME) {
		const ending = `-${suffix++}`;
		candidate = `${base.slice(0, 64 - ending.length)}${ending}`;
	}
	assigned.add(candidate);
	return candidate;
}

function layerIdForProfile(profile: string, used: Set<string>): string {
	const base = `profile-${profile}`;
	let id = base;
	let suffix = 2;
	while (used.has(id)) id = `${base}-${suffix++}`;
	used.add(id);
	return id;
}

/**
 * Reconcile the legacy fallback list with gentle-pi 2.7's named profile store.
 *
 * Existing named profiles are authoritative on reads, which makes changes from
 * /gentle:profiles immediately visible to the fallback runtime. Legacy layers
 * are migrated once by assigning them a stable profile key. The declarative
 * fallback list can be rewritten by the Nix bootstrap at any time, so a linked
 * layer whose profile is missing restores that profile instead of disappearing.
 * The reserved bootstrap profile `current` remains the primary route and is
 * never imported as a fallback.
 */
function reconcileFromGentleProfiles(config: GentleFallbackConfig): GentleFallbackConfig {
	const read = readGentleProfiles();
	if (read.status === "invalid") return config;
	const gentle = read.status === "valid" ? read.file : bootstrapGentleProfiles();
	let gentleChanged = read.status === "missing";
	const assigned = new Set<string>();
	const usedIds = new Set(config.fallbacks.map((layer) => layer.id));
	const fallbacks: FallbackLayer[] = [];

	for (const layer of config.fallbacks) {
		const wasLinked = isValidProfileName(layer.profile);
		const profile = assignProfileName(layer, assigned);
		const stored = gentle.profiles[profile];
		if (stored) {
			fallbacks.push({
				...layer,
				profile,
				model_profiles: fallbackProfilesFromGentle(stored),
			});
			continue;
		}
		// Nix owns the packaged B/C/D layers and may rewrite them before Pi
		// starts, so restore only those declared profiles. A missing custom
		// profile means it was deleted or renamed in /gentle:profiles; dropping
		// its linked layer makes that operation propagate back to fallbacks.
		if (wasLinked && !DECLARATIVE_PROFILE_NAMES.has(profile)) continue;
		gentle.profiles[profile] = gentleProfileFromFallback(layer.model_profiles);
		gentleChanged = true;
		fallbacks.push({ ...layer, profile });
	}

	for (const [profile, stored] of Object.entries(gentle.profiles)) {
		if (profile === PRIMARY_PROFILE_NAME || assigned.has(profile)) continue;
		assigned.add(profile);
		fallbacks.push({
			id: layerIdForProfile(profile, usedIds),
			name: profile,
			profile,
			model_profiles: fallbackProfilesFromGentle(stored),
		});
	}

	if (gentleChanged) atomicWriteJson(gentleProfilesPath(), gentle);
	return { version: 1, fallbacks };
}

function persistFallbacksIntoGentleProfiles(
	config: GentleFallbackConfig,
	linkedBefore: Set<string>,
): GentleFallbackConfig {
	const read = readGentleProfiles();
	if (read.status === "invalid") {
		throw new Error(`Invalid Gentle profiles file: ${gentleProfilesPath()}`);
	}
	const gentle = read.status === "valid" ? read.file : bootstrapGentleProfiles();
	const assigned = new Set<string>();
	const fallbacks = config.fallbacks.map((layer) => {
		const profile = assignProfileName(layer, assigned);
		gentle.profiles[profile] = gentleProfileFromFallback(
			layer.model_profiles,
			gentle.profiles[profile],
		);
		return { ...layer, profile };
	});
	// Profiles created in Gentle's own panel are preserved. Only a profile that
	// was explicitly linked to a layer removed in this fallback editor is pruned.
	for (const profile of linkedBefore) {
		if (!assigned.has(profile) && profile !== gentle.active) delete gentle.profiles[profile];
	}
	atomicWriteJson(gentleProfilesPath(), gentle);
	return { version: 1, fallbacks };
}

function storedLinkedProfiles(): Set<string> {
	try {
		const stored = normalizedConfig(JSON.parse(readFileSync(fallbackConfigPath(), "utf8")));
		if (!stored) return new Set();
		return new Set(
			stored.fallbacks
				.map((layer) => layer.profile)
				.filter((profile): profile is string => isValidProfileName(profile)),
		);
	} catch {
		return new Set();
	}
}

export function readFallbackConfig(): GentleFallbackConfig {
	const path = fallbackConfigPath();
	let config = importedFallbackConfig();
	try {
		if (existsSync(path)) {
			config = normalizedConfig(JSON.parse(readFileSync(path, "utf8"))) ?? config;
		}
	} catch {
		// Keep the packaged declarative defaults when the user file is unreadable.
	}
	const reconciled = reconcileFromGentleProfiles(config);
	if (!existsSync(path) || JSON.stringify(reconciled) !== JSON.stringify(config)) {
		atomicWriteJson(path, reconciled);
	}
	return cloneConfig(reconciled);
}

export function writeFallbackConfig(config: GentleFallbackConfig): GentleFallbackConfig {
	const normalized = normalizedConfig(config);
	if (!normalized) throw new Error("Invalid Gentle fallback configuration");
	const path = fallbackConfigPath();
	const synchronized = persistFallbacksIntoGentleProfiles(normalized, storedLinkedProfiles());
	atomicWriteJson(path, synchronized);
	return cloneConfig(synchronized);
}

export function ensureFallbackConfig(): GentleFallbackConfig {
	return readFallbackConfig();
}

export function fallbackRoutesForAgent(agentName: string): RuntimeFallbackRoute[] {
	const routes: RuntimeFallbackRoute[] = [];
	const active = readGentleProfiles();
	const activeProfile = active.status === "valid" ? active.file.active : undefined;
	for (const layer of readFallbackConfig().fallbacks) {
		// When a named profile is applied, its own route is the primary route; it
		// must not be retried as its own first fallback.
		if (layer.profile && layer.profile === activeProfile) continue;
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
