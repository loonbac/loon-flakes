import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { FallbackEffort } from "./fallback-config.js";

export type AdaptiveMode = "OFF" | "SHADOW" | "ACTIVE_GUARDED";
export interface AdaptiveRoute { provider: string; model: string; requestedEffort: FallbackEffort; effectiveEffort: FallbackEffort; account?: string }
export interface AdaptiveDecision {
  kind: "ADAPTIVE_ASSIGNMENT" | "USE_STATIC_ASSIGNMENT";
  decisionId: string;
  reason: string;
  mode: AdaptiveMode;
  role: string;
  taskClass: string;
  risk: string;
  staticRoute: AdaptiveRoute;
  requestedAdaptiveRoute?: AdaptiveRoute;
  exploration: boolean;
  compiledPrompt?: string;
  promptProfileId?: string;
  promptProfileVersion?: string;
  promptCompilerVersion?: string;
  canonicalContractHash?: string;
  compiledPromptHash?: string;
  promptExecutionStatus?: "ACTUAL" | "COUNTERFACTUAL_UNOBSERVED";
  routingLatencyMs: number;
}

interface RouterResponse { ok: boolean; decision?: AdaptiveDecision; error?: string; [key: string]: unknown }

export const ADAPTIVE_ROUTER_TIMEOUT_MS = 5_000;
export const ADAPTIVE_STATUS_KEY = "loon-natural-adaptive-route";

function projectRoot(): string {
  return process.env.NATURAL_ROUTER_ROOT?.trim() || join(homedir(), "Proyectos", "gentle-jev-adaptive-routing");
}

function entryPoint(): string { return join(projectRoot(), "dist", "src", "host", "entry.js"); }
let activeCatalogCache: { path: string; mtimeNs: bigint; ids: Set<string> } | undefined;
function onboardedRouteAllowed(provider: string, model: string): boolean {
  try {
    const stateDir = process.env.NATURAL_ROUTER_STATE_DIR?.trim() || join(homedir(), ".pi", "agent", "state", "natural-adaptive-routing");
    const path = join(stateDir, "model-catalog.json");
    const mtimeNs = statSync(path, { bigint: true }).mtimeNs;
    if (!activeCatalogCache || activeCatalogCache.path !== path || activeCatalogCache.mtimeNs !== mtimeNs) {
      const catalog = JSON.parse(readFileSync(path, "utf8")) as { schemaVersion?: string; models?: Record<string, { status?: string }> };
      activeCatalogCache = { path, mtimeNs, ids: new Set(catalog.schemaVersion === "model-catalog-v1" ? Object.entries(catalog.models ?? {}).filter(([, card]) => card.status === "ACTIVE").map(([id]) => id) : []) };
    }
    return activeCatalogCache.ids.has(`${provider}/${model}`);
  } catch { return false; }
}

function runtimeModels(ctx: ExtensionContext): Array<Record<string, unknown>> {
  return ctx.modelRegistry.getAvailable().map((model) => {
    const candidate = model as unknown as Record<string, unknown>;
    const map = candidate.thinkingLevelMap && typeof candidate.thinkingLevelMap === "object" ? candidate.thinkingLevelMap as Record<string, unknown> : {};
    const efforts = Object.entries(map).filter(([key, value]) => ["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(key) && typeof value === "string").map(([key]) => key);
    return { provider: model.provider, id: model.id, name: model.name, contextWindow: model.contextWindow,
      reasoning: model.reasoning, input: model.input,
      ...(Array.isArray(candidate.supportedEfforts) ? { supportedEfforts: candidate.supportedEfforts } : efforts.length ? { supportedEfforts: efforts } : {}),
      ...(typeof candidate.supportsTools === "boolean" ? { supportsTools: candidate.supportsTools } : {}),
      ...(typeof candidate.version === "string" ? { version: candidate.version } : {}) };
  });
}

export async function callNaturalRouter(payload: unknown, timeoutMs = ADAPTIVE_ROUTER_TIMEOUT_MS): Promise<RouterResponse> {
  if (!existsSync(entryPoint())) throw new Error(`adaptive router build missing: ${entryPoint()}`);
  return await new Promise<RouterResponse>((resolvePromise, reject) => {
    const child = spawn(process.execPath, [entryPoint()], { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, NATURAL_ROUTER_ROOT: projectRoot() } });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => { child.kill("SIGTERM"); reject(new Error(`adaptive router exceeded ${timeoutMs}ms`)); }, timeoutMs);
    child.stdout.on("data", (chunk) => { stdout += String(chunk); });
    child.stderr.on("data", (chunk) => { stderr += String(chunk); });
    child.on("error", (error) => { clearTimeout(timer); reject(error); });
    child.on("close", (code) => {
      clearTimeout(timer);
      try {
        const response = JSON.parse(stdout.trim()) as RouterResponse;
        if (!response.ok) reject(new Error(response.error || stderr.trim() || `adaptive router exited ${String(code)}`));
        else resolvePromise(response);
      } catch (error) { reject(error instanceof Error ? error : new Error(String(error))); }
    });
    child.stdin.end(JSON.stringify(payload));
  });
}

export function routeMatches(requested: AdaptiveRoute, observed: AdaptiveRoute): boolean {
  return requested.provider === observed.provider && requested.model === observed.model
    && requested.requestedEffort === observed.requestedEffort && requested.effectiveEffort === observed.effectiveEffort;
}

export function validAdaptiveDecision(decision: AdaptiveDecision, agent: string): boolean {
  if (decision.role !== agent || !decision.decisionId || decision.kind !== "ADAPTIVE_ASSIGNMENT") return false;
  const route = decision.requestedAdaptiveRoute;
  if (!route || !route.provider || !route.model || !route.effectiveEffort || !decision.compiledPrompt) return false;
  if (route.model === "claude-opus-4-6") return agent === "jd-judge-b" && route.provider === "antigravity" && route.effectiveEffort === "high";
  return NATURAL_RECOVERY_ALLOWLIST.has(`${route.provider}/${route.model}`) || onboardedRouteAllowed(route.provider, route.model);
}

export function legacyFallbackMayPreempt(adaptivePrimaryApplied: boolean): boolean { return !adaptivePrimaryApplied; }

export function prepareAdaptiveApplication(
  agent: string,
  currentSystemPrompt: string,
  decision: AdaptiveDecision,
): { route: AdaptiveRoute; systemPrompt: string; recoveryInvoked: false } {
  if (!validAdaptiveDecision(decision, agent) || !decision.requestedAdaptiveRoute) throw new Error("invalid adaptive primary decision");
  return {
    route: decision.requestedAdaptiveRoute,
    systemPrompt: adaptivePromptSystemPrompt(currentSystemPrompt, decision),
    recoveryInvoked: false,
  };
}

export function recoveryLineage(primary: AdaptiveRoute, fallback: AdaptiveRoute, reason: string) {
  return {
    primaryAttempt: { attemptIndex: 0, route: primary, disposition: "PROVIDER_FAILURE" as const },
    fallbackAttempt: { attemptIndex: 1, route: fallback, lineage: "RECOVERY_FALLBACK" as const, reason },
  };
}

const NATURAL_RECOVERY_ALLOWLIST = new Set([
  "opencode-go/deepseek-v4.1-flash", "opencode-go/glm-5.3-flash",
  "opencode-go/muse-spark-1.3-contributor", "opencode-go/mimo-v2.5",
  "commandcode/Qwen/Qwen3.8-Flash", "commandcode/deepseek/deepseek-v4.1-flash",
  "commandcode/z-ai/glm-5.3-flash", "commandcode/meta/muse-spark-1.3-contributor",
  "commandcode/xiaomi/mimo-v2.5", "antigravity/gemini-3.8-flash",
  "antigravity-alt/gemini-3.8-flash", "openai-codex/gpt-5.6-luna",
  "openai-codex/gpt-5.6-terra", "openai-codex/gpt-5.6-sol",
]);

export function adaptiveRecoveryRouteAllowed(route: Pick<AdaptiveRoute, "provider" | "model">, agentName: string | undefined): boolean {
  if (route.model === "claude-opus-4-6") return agentName === "jd-judge-b";
  if (agentName === "jd-judge-b") return false;
  return NATURAL_RECOVERY_ALLOWLIST.has(`${route.provider}/${route.model}`) || onboardedRouteAllowed(route.provider, route.model);
}

export function hasExplicitGentleProfilePin(cwd: string): boolean {
  if (existsSync(join(cwd, ".pi", "gentle-ai", "profile.json"))) return true;
  const result = spawnSync("git", ["rev-parse", "--git-common-dir"], { cwd, encoding: "utf8", timeout: 500, stdio: ["ignore", "pipe", "ignore"] });
  if (result.status !== 0 || !result.stdout.trim()) return false;
  const common = resolve(cwd, result.stdout.trim());
  return existsSync(join(common, "gentle-ai", "profile-pin.json"));
}

export function routeDiffersFromConfiguredGentleDefault(agent: string, current: AdaptiveRoute): boolean {
  const gentleDir = process.env.GENTLE_PI_CONFIG_HOME?.trim() || join(homedir(), ".pi", "gentle-ai");
  try {
    const value = JSON.parse(readFileSync(join(gentleDir, "profiles.json"), "utf8")) as {
      active?: string;
      profiles?: Record<string, Record<string, { model?: string; thinking?: FallbackEffort }>>;
    };
    const active = value.active;
    const configured = active ? value.profiles?.[active]?.[agent] : undefined;
    if (!configured?.model) return false;
    const expected = configured.model.split("/");
    const provider = expected.shift();
    const model = expected.join("/");
    return provider !== current.provider || model !== current.model
      || (configured.thinking !== undefined && configured.thinking !== current.requestedEffort);
  } catch { return false; }
}

export async function resolveAdaptivePrimary(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  agent: string,
  prompt: string,
): Promise<AdaptiveDecision> {
  if (!ctx.model) throw new Error("static model is unavailable");
  const effort = pi.getThinkingLevel() as FallbackEffort;
  const staticRoute: AdaptiveRoute = { provider: ctx.model.provider, model: ctx.model.id, requestedEffort: effort, effectiveEffort: effort };
  const response = await callNaturalRouter({
    action: "route", agent, role: agent, task: prompt, cwd: ctx.cwd,
    staticRoute,
    explicitUserOverride: hasExplicitGentleProfilePin(ctx.cwd) || routeDiffersFromConfiguredGentleDefault(agent, staticRoute),
    availableModels: ctx.modelRegistry.getAvailable().map((model) => ({ provider: model.provider, model: model.id })),
    allowedTools: pi.getActiveTools(),
  });
  if (!response.decision) throw new Error("adaptive router returned no decision");
  return response.decision;
}

export async function recordObservedRoute(decision: AdaptiveDecision, observed: AdaptiveRoute): Promise<void> {
  await callNaturalRouter({ action: "observe", decisionId: decision.decisionId, role: decision.role, requested: decision.requestedAdaptiveRoute, observed });
}

export async function recordAdaptiveFailure(reason: string): Promise<void> {
  try { await callNaturalRouter({ action: "router-failure", reason }); } catch { /* fail-open telemetry must not break Pi */ }
}

export async function recordAdaptiveInvariant(reason: string): Promise<void> {
  try { await callNaturalRouter({ action: "fatal-invariant", reason }); } catch { /* local fail-open remains static */ }
}

export function adaptivePromptSystemPrompt(existing: string, decision: AdaptiveDecision): string {
  if (!decision.compiledPrompt) return existing;
  return `${existing}\n\n# Adaptive work-unit contract\n\n${decision.compiledPrompt}`;
}

function notifyJson(ctx: ExtensionContext, title: string, value: unknown): void {
  const rendered = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  ctx.ui.notify(`${title}\n${rendered.slice(0, 6_000)}`, "info");
}

function notifyModelOnboarding(ctx: ExtensionContext, value: RouterResponse): void {
  const result = value.result as { receipt?: Record<string, unknown>; dryRun?: boolean; catalogMutated?: boolean; preservedActiveModel?: boolean } | undefined;
  const card = result?.receipt;
  if (!card) { notifyJson(ctx, "Model onboarding", value); return; }
  const fits = Array.isArray(card.taskFits) ? card.taskFits as Array<{ roleState?: string }> : [];
  const count = (state: string) => fits.filter((item) => item.roleState === state).length;
  const runtime = card.runtime as { provider?: string; id?: string; supportedEfforts?: string[] } | undefined;
  const envelope = card.capabilityEnvelope as Record<string, { state?: string; assessment?: string }> | undefined;
  const research = card.research as { status?: string; usage?: Record<string, number>; sources?: unknown[]; contradictions?: unknown[] } | undefined;
  const dimensions = Object.entries(envelope ?? {}).filter(([, dimension]) => dimension.state !== "UNKNOWN").map(([name, dimension]) => `  ${name}: ${dimension.assessment}`).join("\n") || "  UNKNOWN (no verified public benchmark prior)";
  const usage = research?.usage;
  const lines = [
    result?.dryRun ? "MODEL ONBOARDING DRY RUN" : "MODEL ONBOARDED",
    `model: ${String(card.id ?? "unknown")}`,
    `runtime: ${runtime?.provider ?? "unknown"}/${runtime?.id ?? "unknown"}`,
    `version: ${String(card.modelVersion ?? "unknown")} (${String(card.versionKind ?? "unknown")})`,
    `efforts: ${runtime?.supportedEfforts?.join(", ") || "not observable"}`,
    `benchmark evidence:\n${dimensions}`,
    `routing: normal ${count("NORMAL_CANDIDATE")}, exploration ${count("EXPLORATION_ONLY")}, shadow ${count("SHADOW_ONLY")}, prohibited ${count("NOT_ELIGIBLE")}`,
    `local evidence: UNPROVEN; verified runs 0`,
    `research: ${research?.status ?? "unknown"}; Gemini ${usage?.primaryCalls ?? 0}, Jev ${usage?.jevCalls ?? 0} (${usage?.jevCacheHits ?? 0} cache hits), DeepSeek ${usage?.verifierCalls ?? 0}, Terra ${usage?.escalationCalls ?? 0}`,
    `sources: ${research?.sources?.length ?? 0}; contradictions: ${research?.contradictions?.length ?? 0}`,
    `prompt: ${Array.isArray((card.promptCard as { documentedGuidance?: unknown[] } | undefined)?.documentedGuidance) && (card.promptCard as { documentedGuidance: unknown[] }).documentedGuidance.length ? "verified documented guidance" : "neutral task-derived"}`,
    `status: ${String(card.status ?? "unknown")}; catalog mutated: ${result?.catalogMutated === true ? "yes" : "no"}`,
    ...(result?.preservedActiveModel ? ["Existing active model preserved after incomplete refresh."] : []),
    ...((card.warnings as string[] | undefined) ?? []).slice(0, 4).map((warning) => `warning: ${warning}`),
  ];
  ctx.ui.notify(lines.join("\n"), "info");
}

export function registerAdaptiveCommands(pi: ExtensionAPI): void {
  pi.registerCommand("adaptive", {
    description: "Natural adaptive routing: status|models|model-add|model-info|model-remove|model-refresh|model-doctor|active|shadow|off|explain|quota|history",
    handler: async (args, ctx) => {
      const [command = "status", model, ...flags] = args.trim().split(/\s+/u);
      try {
        if (["models", "model-add", "model-info", "model-remove", "model-refresh", "model-doctor"].includes(command)) {
          if (command !== "models" && (!model || model.startsWith("--"))) throw new Error("usage: /adaptive model-add provider/model-id [--dry-run]");
          const researchMode = flags.includes("--offline") ? "OFFLINE" : flags.includes("--cached") ? "CACHED" : "ONLINE";
          const response = await callNaturalRouter({ action: command, model, dryRun: flags.includes("--dry-run"), researchMode, availableModels: runtimeModels(ctx) }, command === "model-add" || command === "model-refresh" ? 480_000 : ADAPTIVE_ROUTER_TIMEOUT_MS);
          if (command === "model-add" || command === "model-refresh") notifyModelOnboarding(ctx, response);
          else notifyJson(ctx, `Adaptive ${command}`, response);
          return;
        }
        if (["active", "shadow", "off"].includes(command)) {
          const mode = command === "active" ? "ACTIVE_GUARDED" : command.toUpperCase();
          notifyJson(ctx, "Adaptive routing", await callNaturalRouter({ action: "set-mode", mode }));
          return;
        }
        const action = command === "quota" ? "quota" : command === "history" ? "history" : command === "explain" ? "explain" : "status";
        notifyJson(ctx, `Adaptive ${action}`, await callNaturalRouter({ action, ...(action === "quota" ? { force: true } : {}) }, action === "quota" ? 15_000 : ADAPTIVE_ROUTER_TIMEOUT_MS));
      } catch (error) {
        ctx.ui.notify(`Adaptive router no disponible; la ruta estática permanece intacta: ${error instanceof Error ? error.message : String(error)}`, "warning");
      }
    },
  });
}

export function readInstalledRouterCommit(): string | undefined {
  try { return readFileSync(join(projectRoot(), ".git", "HEAD"), "utf8").trim(); } catch { return undefined; }
}
