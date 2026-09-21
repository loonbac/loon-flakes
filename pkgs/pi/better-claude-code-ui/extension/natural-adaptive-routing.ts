import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
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
  return NATURAL_RECOVERY_ALLOWLIST.has(`${route.provider}/${route.model}`);
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
  return NATURAL_RECOVERY_ALLOWLIST.has(`${route.provider}/${route.model}`);
}

export function hasExplicitGentleProfilePin(cwd: string): boolean {
  if (existsSync(join(cwd, ".pi", "gentle-ai", "profile.json"))) return true;
  const result = spawnSync("git", ["rev-parse", "--git-common-dir"], { cwd, encoding: "utf8", timeout: 500, stdio: ["ignore", "pipe", "ignore"] });
  if (result.status !== 0 || !result.stdout.trim()) return false;
  const common = resolve(cwd, result.stdout.trim());
  return existsSync(join(common, "gentle-ai", "profile-pin.json"));
}

export async function resolveAdaptivePrimary(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  agent: string,
  prompt: string,
): Promise<AdaptiveDecision> {
  if (!ctx.model) throw new Error("static model is unavailable");
  const effort = pi.getThinkingLevel() as FallbackEffort;
  const response = await callNaturalRouter({
    action: "route", agent, role: agent, task: prompt, cwd: ctx.cwd,
    staticRoute: { provider: ctx.model.provider, model: ctx.model.id, requestedEffort: effort, effectiveEffort: effort },
    explicitUserOverride: hasExplicitGentleProfilePin(ctx.cwd),
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

export function registerAdaptiveCommands(pi: ExtensionAPI): void {
  pi.registerCommand("adaptive", {
    description: "Natural adaptive routing: status|active|shadow|off|explain|quota|history",
    handler: async (args, ctx) => {
      const [command = "status"] = args.trim().split(/\s+/u);
      try {
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
