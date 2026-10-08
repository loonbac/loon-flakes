#!/usr/bin/env python3
"""Genera la pagina de nueva pestana: un panel de todo el trabajo del router.

Lee tres familias de datos y escribe un HTML autocontenido:

  * La paleta del fondo de pantalla, para que el acento de la pagina sea el mismo
    que el del escritorio. Se lee del archivo que ya escribe `accent-wallpaper`,
    en orden de preferencia: waybar/colors.css (paleta completa), mpvpaper/accent.txt,
    hypr/colors.conf. Si ninguno existe, la pagina funciona con el acento por defecto.

  * Las sesiones de Pi, que son la unica fuente real de tokens y de dinero. Cada
    linea de uso trae `totalTokens` y `cost.total`; agregarlos por modelo y por dia
    da el total, el mes y el dia en curso.

  * El estado del router: catalogo de modelos, decisiones y evidencia local. Esto
    responde "que modelo se esta usando ahora" y "que ha aprendido el sistema".

El HTML se escribe completo en cada corrida y la pagina se recarga sola, asi que el
panel sigue al trabajo sin ningun servidor ni conexion a red.
"""

import json
import os
import re
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
PI = HOME / ".pi" / "agent"
STATE = PI / "state" / "natural-adaptive-routing"
OUT = HOME / ".local" / "share" / "newtab"

# Cuantas decisiones recientes se muestran, y cuan reciente tiene que ser la ultima
# para que la pagina diga que el router esta trabajando en este momento.
RECENT_DECISIONS = 40
LIVE_WINDOW_SECONDS = 180


def read_text(path):
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def read_json(path, fallback=None):
    text = read_text(path)
    if not text:
        return fallback
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return fallback


def read_jsonl(path):
    """Lee un JSONL tolerando lineas rotas.

    La historia de este archivo incluye registros de esquemas anteriores, y una sola
    linea ilegible no puede llevarse puesta la pagina entera.
    """
    rows = []
    for line in read_text(path).splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return rows


# --------------------------------------------------------------------------- color


def wallpaper_palette():
    """La paleta del fondo de pantalla, tal como la dejo `accent-wallpaper`.

    Se prefiere colors.css porque trae la paleta completa y no solo el acento; el
    acento suelto y el colors.conf de Hyprland quedan como respaldo. El orden importa:
    colors.conf lo escribe Nix una sola vez y no sigue al fondo, asi que es el ultimo.
    """
    palette = {}

    css = read_text(HOME / ".config" / "waybar" / "colors.css")
    for name, value in re.findall(r"@define-color\s+([a-z0-9_]+)\s+(#[0-9A-Fa-f]{6})", css):
        palette[name] = value

    if "accent" not in palette:
        accent = read_text(HOME / ".config" / "mpvpaper" / "accent.txt").strip()
        if re.fullmatch(r"#[0-9A-Fa-f]{6}", accent):
            palette["accent"] = accent

    if "accent" not in palette:
        conf = read_text(HOME / ".config" / "hypr" / "colors.conf")
        for name, value in re.findall(r"\$([a-z_]+)\s*=\s*rgb\(([0-9A-Fa-f]{6})\)", conf):
            palette[name] = "#" + value

    return palette


def mix(hex_color, other, ratio):
    """Mezcla dos colores; se usa para derivar tonos que la paleta no trae."""
    def parts(value):
        value = value.lstrip("#")
        return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))

    a, b = parts(hex_color), parts(other)
    return "#%02x%02x%02x" % tuple(round(x + (y - x) * ratio) for x, y in zip(a, b))


def relative_luminance(hex_color):
    def channel(value):
        value = value / 255
        return value / 12.92 if value <= 0.03928 else ((value + 0.055) / 1.055) ** 2.4

    r, g, b = (int(hex_color.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


# ------------------------------------------------------------------- uso de tokens


def usage_from_sessions():
    """Agrega tokens y costo desde las sesiones de Pi.

    Es la unica fuente honesta de consumo: el registro del router solo guarda las
    corridas que el mismo eligio, mientras que las sesiones guardan todo lo que Pi
    hizo, incluido lo que corrio en modo estatico.
    """
    sessions = PI / "sessions"
    now = datetime.now(timezone.utc)
    today = now.date()
    month = (now.year, now.month)

    per_model = defaultdict(lambda: {"tokens": 0, "cost": 0.0, "calls": 0,
                                     "todayTokens": 0, "todayCost": 0.0,
                                     "monthTokens": 0, "monthCost": 0.0,
                                     "lastSeen": None})
    totals = {"tokens": 0, "cost": 0.0, "calls": 0,
              "todayTokens": 0, "todayCost": 0.0,
              "monthTokens": 0, "monthCost": 0.0}
    per_day = defaultdict(lambda: {"tokens": 0, "cost": 0.0})

    if not sessions.is_dir():
        return per_model, totals, per_day

    for path in sessions.rglob("*.jsonl"):
        provider = model = None
        try:
            handle = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with handle:
            for line in handle:
                if '"usage"' not in line and '"model_change"' not in line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue

                kind = row.get("type")
                if kind == "model_change":
                    provider = row.get("provider") or provider
                    model = row.get("modelId") or model
                    continue
                if kind != "message":
                    continue

                message = row.get("message") or {}
                usage = message.get("usage")
                if not isinstance(usage, dict):
                    continue

                provider = message.get("provider") or provider
                model = message.get("model") or model
                if not model:
                    continue

                tokens = usage.get("totalTokens") or 0
                if not tokens:
                    tokens = sum(usage.get(key) or 0 for key in
                                 ("input", "output", "cacheRead", "cacheWrite"))
                cost = (usage.get("cost") or {}).get("total") or 0.0

                stamp = row.get("timestamp")
                moment = None
                if isinstance(stamp, str):
                    try:
                        moment = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
                    except ValueError:
                        moment = None

                entry = per_model[f"{provider or '?'}/{model}"]
                for bucket in (entry, totals):
                    bucket["tokens"] += tokens
                    bucket["cost"] += cost
                    bucket["calls"] += 1
                if moment is not None:
                    entry["lastSeen"] = max(entry["lastSeen"] or stamp, stamp)
                    if moment.date() == today:
                        for bucket in (entry, totals):
                            bucket["todayTokens"] += tokens
                            bucket["todayCost"] += cost
                    if (moment.year, moment.month) == month:
                        for bucket in (entry, totals):
                            bucket["monthTokens"] += tokens
                            bucket["monthCost"] += cost
                    day = moment.date().isoformat()
                    per_day[day]["tokens"] += tokens
                    per_day[day]["cost"] += cost

    return per_model, totals, per_day


# ----------------------------------------------------------------- router y cuota


def router_state():
    control = read_json(STATE / "control.json", {}) or {}
    catalog = (read_json(STATE / "model-catalog.json", {}) or {}).get("models", {}) or {}
    receipts = read_jsonl(STATE / "route-receipts.jsonl")
    observations = read_jsonl(STATE / "route-observations.jsonl")
    quota = read_jsonl(STATE / "quota-cache.jsonl")

    now = time.time()

    def age_of(stamp):
        if not isinstance(stamp, str):
            return None
        try:
            moment = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        except ValueError:
            return None
        return now - moment.timestamp()

    decisions = []
    adaptive = static = 0
    for row in receipts:
        kind = row.get("kind")
        if kind == "ADAPTIVE_ASSIGNMENT":
            adaptive += 1
        elif kind == "USE_STATIC_ASSIGNMENT":
            static += 1
        decisions.append({
            "at": row.get("recordedAt"),
            "age": age_of(row.get("recordedAt")),
            "kind": kind,
            "role": row.get("role"),
            "taskClass": row.get("taskClass"),
            "risk": row.get("risk"),
            "reason": row.get("reason"),
            "provider": (row.get("requestedAdaptiveRoute") or {}).get("provider"),
            "model": (row.get("requestedAdaptiveRoute") or {}).get("model"),
            "effort": (row.get("requestedAdaptiveRoute") or {}).get("effort"),
            "exploration": row.get("exploration"),
            "latency": row.get("routingLatencyMs"),
        })

    decisions.sort(key=lambda item: item["at"] or "")
    recent = decisions[-RECENT_DECISIONS:][::-1]
    last_adaptive = next((item for item in reversed(decisions)
                          if item["kind"] == "ADAPTIVE_ASSIGNMENT"), None)
    last_any = decisions[-1] if decisions else None

    live = bool(last_adaptive and last_adaptive["age"] is not None
                and last_adaptive["age"] < LIVE_WINDOW_SECONDS)

    # La evidencia local es lo que el sistema aprendio: por modelo, cuantas corridas
    # resueltas tiene y que proporcion pasaron.
    evidence = {}
    for row in observations:
        if not row.get("evidenceAdmitted"):
            continue
        model = row.get("model") or row.get("modelId")
        if not model:
            continue
        slot = evidence.setdefault(model, {"runs": 0, "passed": 0})
        slot["runs"] += 1

    # La cuota se guarda como una linea por sondeo, y cada sondeo trae la lista de
    # proveedores. Interesa el ultimo sondeo, no el historico, asi que se lee la
    # ultima linea que traiga instantaneas y se toma esa como el estado vigente.
    quotas = []
    for row in reversed(quota):
        snapshots = row.get("snapshots")
        if isinstance(snapshots, list) and snapshots:
            for snapshot in snapshots:
                if not isinstance(snapshot, dict):
                    continue
                windows = []
                for window in (snapshot.get("windows") or []):
                    if not isinstance(window, dict):
                        continue
                    remaining = window.get("remainingFraction")
                    windows.append({
                        "id": window.get("id"),
                        "label": window.get("label") or window.get("id"),
                        "kind": window.get("kind"),
                        "remaining": remaining,
                        "used": window.get("usedFraction"),
                        "resetAt": window.get("resetAt"),
                        "hard": window.get("hardRequired", False),
                    })
                # Solo las ventanas que de verdad limitan algo: una ventana
                # informativa que el proveedor nunca declaro no dice nada sobre
                # el margen real, y mostrarla lo haria parecer mas ajustado.
                hard = [w for w in windows if w["hard"]]
                tightest = min((w["remaining"] for w in hard if w["remaining"] is not None),
                               default=None)
                quotas.append({
                    "alias": snapshot.get("accountAlias") or snapshot.get("provider"),
                    "provider": snapshot.get("provider"),
                    "health": snapshot.get("health"),
                    "observedAt": snapshot.get("observedAt"),
                    "tightest": tightest,
                    "windows": sorted(windows, key=lambda w: w["remaining"] if w["remaining"] is not None else 9),
                })
            break

    active = {key: value for key, value in catalog.items()
              if value.get("status") == "ACTIVE"}

    return {
        "control": control,
        "counts": {
            "catalog": len(catalog),
            "active": len(active),
            "free": sum(1 for key in active
                        if ":free" in key or "-free" in key),
            "receipts": len(receipts),
            "observations": len(observations),
            "adaptive": adaptive,
            "static": static,
        },
        "decisions": recent,
        "lastAdaptive": last_adaptive,
        "lastAny": last_any,
        "live": live,
        "evidence": evidence,
        "quotas": quotas,
        "activeModels": sorted(active),
    }


def agents_section(router):
    """Los agentes y el modelo que tienen asignado, con cuantas veces trabajaron.

    El perfil es el piso, no la decision: el router puede elegir otro modelo por
    delegacion. Por eso se muestran los dos datos: lo asignado y lo que realmente
    paso, tomado de las decisiones que nombran al agente.
    """
    profiles = ((read_json(PI / "subagents.json", {}) or {}).get("model_profiles")) or {}

    per_agent = defaultdict(lambda: {"decisions": 0, "adaptive": 0, "static": 0,
                                     "models": defaultdict(int), "lastAt": None})
    for row in read_jsonl(STATE / "route-receipts.jsonl"):
        role = row.get("role")
        if not role:
            continue
        slot = per_agent[role]
        slot["decisions"] += 1
        if row.get("kind") == "ADAPTIVE_ASSIGNMENT":
            slot["adaptive"] += 1
            route = row.get("requestedAdaptiveRoute") or {}
            if route.get("model"):
                slot["models"][f"{route.get('provider')}/{route.get('model')}"] += 1
        elif row.get("kind") == "USE_STATIC_ASSIGNMENT":
            slot["static"] += 1
        stamp = row.get("recordedAt")
        if isinstance(stamp, str) and (slot["lastAt"] is None or stamp > slot["lastAt"]):
            slot["lastAt"] = stamp

    names = sorted(set(list(profiles) + list(per_agent)))
    out = []
    for name in names:
        profile = profiles.get(name) or {}
        activity = per_agent.get(name) or {"decisions": 0, "adaptive": 0, "static": 0,
                                           "models": {}, "lastAt": None}
        assigned = profile.get("model")
        if assigned and profile.get("thinking"):
            assigned = f"{assigned} · {profile['thinking']}"
        watched = sorted(activity["models"].items(), key=lambda item: -item[1])
        out.append({
            "name": name,
            "assigned": assigned or "hereda el del perfil",
            "decisions": activity["decisions"],
            "adaptive": activity["adaptive"],
            "static": activity["static"],
            "lastAt": activity["lastAt"],
            "actuallyUsed": [{"model": key, "times": times} for key, times in watched[:3]],
        })
    out.sort(key=lambda item: (-item["decisions"], item["name"]))
    return out


def antigravity_accounts():
    data = read_json(PI / "antigravity-accounts.json", {}) or {}
    accounts = data.get("accounts") if isinstance(data, dict) else None
    if isinstance(accounts, list):
        return [item.get("email") or item.get("id") for item in accounts if isinstance(item, dict)]
    if isinstance(data, dict):
        return [key for key in data if key not in ("active", "current", "version")]
    return []


# ----------------------------------------------------------------------- la pagina


def human_tokens(value):
    value = float(value or 0)
    for unit, size in (("B", 1e9), ("M", 1e6), ("k", 1e3)):
        if value >= size:
            return f"{value / size:.1f}{unit}"
    return f"{int(value)}"


def money(value):
    value = float(value or 0)
    if value == 0:
        return "0"
    if value < 0.01:
        return f"{value:.4f}"
    if value < 1:
        return f"{value:.3f}"
    return f"{value:,.2f}"


def seconds_ago(age):
    if age is None:
        return "—"
    if age < 60:
        return f"hace {int(age)}s"
    if age < 3600:
        return f"hace {int(age / 60)}m"
    if age < 86400:
        return f"hace {int(age / 3600)}h"
    return f"hace {int(age / 86400)}d"


def build_document(palette, per_model, totals, per_day, router, accounts):
    accent = palette.get("accent", "#7aa2f7")
    background = palette.get("background", "#1A1A1A")
    surface = palette.get("surface", palette.get("background_alt", "#232323"))
    foreground = palette.get("foreground", "#E1E6F0")
    muted = palette.get("muted", "#777E8C")
    highlight = palette.get("highlight", accent)
    warning = palette.get("warning", "#E6A545")
    critical = palette.get("critical", "#E6506B")

    # La paleta trae lo que el escritorio usa; lo que falta se deriva para que la
    # pagina siga viendose coherente con cualquier fondo de pantalla.
    on_accent = palette.get("on_accent")
    if not on_accent:
        on_accent = "#000000" if relative_luminance(accent) > 0.4 else "#ffffff"
    edge = mix(surface, foreground, 0.18)

    models = []
    for key, usage in sorted(per_model.items(), key=lambda item: -item[1]["cost"]):
        provider, _, name = key.partition("/")
        models.append({
            "key": key,
            "provider": provider,
            "name": name,
            "tokens": usage["tokens"],
            "tokensText": human_tokens(usage["tokens"]),
            "cost": round(usage["cost"], 4),
            "costText": money(usage["cost"]),
            "calls": usage["calls"],
            "todayTokens": usage["todayTokens"],
            "todayCost": usage["todayCost"],
            "monthTokens": usage["monthTokens"],
            "monthCost": usage["monthCost"],
            "lastSeen": usage["lastSeen"],
            "live": False,
        })

    # Un modelo "en uso" es el de la ultima decision adaptativa todavia fresca.
    live_model = None
    if router["live"] and router["lastAdaptive"]:
        route = router["lastAdaptive"]
        live_model = f"{route['provider']}/{route['model']}"
        for item in models:
            if item["key"] == live_model:
                item["live"] = True

    # Dias para la grafica; los ultimos 30, rellenando los ausentes con cero para
    # que un dia sin trabajo se vea como un hueco y no como una linea que lo saltea.
    days = sorted(per_day)[-30:]
    daily = [{"day": day, "tokens": per_day[day]["tokens"],
              "cost": round(per_day[day]["cost"], 4)} for day in days]
    peak = max((item["tokens"] for item in daily), default=0) or 1

    payload = {
        "generatedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
        "accent": accent,
        "live": router["live"],
        "liveModel": live_model,
        "totals": {
            "tokens": totals["tokens"], "tokensText": human_tokens(totals["tokens"]),
            "cost": round(totals["cost"], 4), "costText": money(totals["cost"]),
            "calls": totals["calls"],
            "todayTokens": totals["todayTokens"], "todayTokensText": human_tokens(totals["todayTokens"]),
            "todayCost": round(totals["todayCost"], 4), "todayCostText": money(totals["todayCost"]),
            "monthTokens": totals["monthTokens"], "monthTokensText": human_tokens(totals["monthTokens"]),
            "monthCost": round(totals["monthCost"], 4), "monthCostText": money(totals["monthCost"]),
        },
        "counts": router["counts"],
        "control": {
            "mode": router["control"].get("mode"),
            "breaker": router["control"].get("circuitBreaker"),
            "exploration": router["control"].get("explorationEnabled"),
            "canary": f"{router['control'].get('cleanCanaryLaunches', 0)}/{router['control'].get('canaryTarget', 0)}",
        },
        "models": models[:60],
        "decisions": [{
            "at": item["at"], "ago": seconds_ago(item["age"]), "kind": item["kind"],
            "role": item["role"], "taskClass": item["taskClass"], "risk": item["risk"],
            "model": (f"{item['provider']}/{item['model']}" if item["model"] else None),
            "effort": item["effort"], "exploration": item["exploration"],
            "latency": item["latency"],
            "reason": (item["reason"] or "")[:90],
        } for item in router["decisions"]],
        "daily": daily,
        "peak": peak,
        "quotas": router["quotas"],
        "accounts": accounts,
    }

    payload["agents"] = agents_section(router)

    return TEMPLATE.replace("__PAYLOAD__", json.dumps(payload, ensure_ascii=False)) \
                   .replace("__ACCENT__", accent) \
                   .replace("__BACKGROUND__", background) \
                   .replace("__SURFACE__", surface) \
                   .replace("__FOREGROUND__", foreground) \
                   .replace("__MUTED__", muted) \
                   .replace("__HIGHLIGHT__", highlight) \
                   .replace("__WARNING__", warning) \
                   .replace("__CRITICAL__", critical) \
                   .replace("__ON_ACCENT__", on_accent) \
                   .replace("__EDGE__", edge)


TEMPLATE = (Path(__file__).parent / "newtab.template.html").read_text(encoding="utf-8")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    palette = wallpaper_palette()
    per_model, totals, per_day = usage_from_sessions()
    router = router_state()
    document = build_document(palette, per_model, totals, per_day, router,
                              antigravity_accounts())
    target = OUT / "index.html"
    target.write_text(document, encoding="utf-8")
    if "--quiet" not in sys.argv:
        print(f"{target} · {len(document)} bytes · acento {palette.get('accent', 'por defecto')} "
              f"· {totals['tokens']:,} tokens · ${totals['cost']:.2f}")


if __name__ == "__main__":
    main()
