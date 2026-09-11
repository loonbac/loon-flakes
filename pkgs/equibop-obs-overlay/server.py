#!/usr/bin/env python3
"""Overlay local para OBS alimentado por el plugin de voz de Equibop.

Escucha solamente en loopback. El estado vive bajo XDG_RUNTIME_DIR, con
permisos privados del usuario que ejecuta Equibop y OBS.
"""

from __future__ import annotations

import json
import os
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


PORT = 5123
RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", f"/tmp/equibop-obs-{os.getuid()}"))
STATE_PATH = RUNTIME_DIR / "equibop-obs-overlay" / "state.json"
EMPTY_STATE = {"channel_id": None, "members": []}
OVERLAY_VERSION = str(Path(__file__).resolve())


def read_state() -> dict:
    try:
        value = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        if isinstance(value, dict) and isinstance(value.get("members"), list):
            return value
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        pass
    return EMPTY_STATE


PAGE = """<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Equibop voice overlay</title>
  <style>
    :root {
      color-scheme: dark;
      --avatar-size: 182px;
      --gap: 18px;
      --edge: 18px;
      --bottom: 26px;
      --motion: 360ms cubic-bezier(.22, .8, .22, 1);
    }
    * { box-sizing: border-box; }
    html, body, #members { width: 100%; height: 100%; }
    body { margin: 0; background: transparent; overflow: hidden; }
    #members { position: relative; overflow: hidden; }
    .member {
      position: absolute;
      left: calc(var(--edge) + var(--slot) * (var(--avatar-size) + var(--gap)));
      bottom: var(--bottom);
      width: var(--avatar-size);
      height: var(--avatar-size);
      opacity: 1;
      transform: translateY(0);
      transition: left var(--motion), transform var(--motion), opacity 220ms ease;
      will-change: left, transform, opacity;
    }
    .member.entering, .member.leaving {
      opacity: 0;
      transform: translateY(230px);
    }
    .avatar {
      display: block;
      width: 100%;
      height: 100%;
      border: 5px solid #23a55a;
      border-radius: 0;
      object-fit: cover;
      background: #2b2d31;
      box-shadow: 0 8px 20px rgba(0, 0, 0, .38), 0 0 0 3px rgba(35, 165, 90, .3);
      filter: grayscale(0) brightness(1);
      transition: filter 280ms ease, border-color 280ms ease, box-shadow 280ms ease;
    }
    #members.deafened .member:not(.entering):not(.leaving) {
      opacity: .26;
    }
    #members.deafened .avatar {
      filter: grayscale(1) brightness(.48);
      border-color: #777982;
      box-shadow: 0 8px 18px rgba(0, 0, 0, .24), 0 0 0 2px rgba(160, 162, 172, .16);
    }
    .idle {
      position: absolute;
      inset: 0;
      z-index: 5;
      display: grid;
      place-content: center;
      justify-items: center;
      color: #f4f5f7;
      opacity: 1;
      transform: translateY(0);
      transition: opacity 240ms ease, transform var(--motion);
      pointer-events: none;
    }
    .idle.hidden {
      opacity: 0;
      transform: translateY(46px);
    }
    .silence-dots {
      position: absolute;
      inset: 0;
      z-index: 4;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 9px;
      opacity: 1;
      transform: translateY(0);
      transition: opacity 180ms ease, transform 240ms ease;
      pointer-events: none;
    }
    .silence-dots.hidden {
      opacity: 0;
      transform: translateY(16px);
    }
    .silence-dot {
      width: 9px;
      height: 9px;
      border-radius: 50%;
      background: rgba(235, 236, 245, .72);
      box-shadow: 0 0 12px rgba(184, 188, 255, .32);
      animation: dot-wave 1.25s ease-in-out infinite;
    }
    .silence-dot:nth-child(2) { animation-delay: 140ms; }
    .silence-dot:nth-child(3) { animation-delay: 280ms; }
    .idle-icons {
      position: relative;
      width: 190px;
      height: 82px;
      margin-bottom: 12px;
    }
    .idle-icon {
      position: absolute;
      display: grid;
      place-items: center;
      width: 58px;
      height: 58px;
      color: #c9cdfb;
      background: rgba(30, 31, 45, .82);
      border: 1px solid rgba(184, 188, 255, .32);
      border-radius: 16px;
      box-shadow: 0 10px 24px rgba(0, 0, 0, .28);
      animation: float 3.2s ease-in-out infinite;
    }
    .idle-icon svg { width: 30px; height: 30px; }
    .idle-icon:nth-child(1) { left: 0; top: 17px; animation-delay: -.7s; }
    .idle-icon:nth-child(2) { left: 66px; top: 0; width: 62px; height: 62px; color: #fff; animation-delay: -1.8s; }
    .idle-icon:nth-child(3) { right: 0; top: 17px; animation-delay: -2.5s; }
    .idle-title {
      font: 700 17px/1.1 system-ui, sans-serif;
      letter-spacing: .16em;
      text-align: center;
    }
    .idle-hint {
      margin-top: 7px;
      color: rgba(235, 236, 245, .68);
      font: 500 12px/1.2 system-ui, sans-serif;
      text-align: center;
    }
    @keyframes float {
      0%, 100% { transform: translateY(0) rotate(-1deg); }
      50% { transform: translateY(-8px) rotate(1deg); }
    }
    @keyframes dot-wave {
      0%, 60%, 100% { opacity: .35; transform: translateY(0) scale(.85); }
      30% { opacity: 1; transform: translateY(-7px) scale(1); }
    }
    @media (prefers-reduced-motion: reduce) {
      .idle-icon, .silence-dot { animation: none; }
    }
  </style>
</head>
<body>
  <div id="members">
    <section id="idle" class="idle">
      <div class="idle-icons" aria-hidden="true">
        <span class="idle-icon">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="9" cy="8" r="3"/><path d="M3.8 19c.5-3.1 2.2-5 5.2-5s4.7 1.9 5.2 5M18 8v6M15 11h6"/></svg>
        </span>
        <span class="idle-icon">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 14v-2a8 8 0 0 1 16 0v2"/><path d="M4 14a2 2 0 0 1 2-2h1v7H6a2 2 0 0 1-2-2zm16 0a2 2 0 0 0-2-2h-1v7h1a2 2 0 0 0 2-2z"/></svg>
        </span>
        <span class="idle-icon">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 10v4M8 7v10M12 4v16M16 7v10M20 10v4"/></svg>
        </span>
      </div>
      <div id="idle-title" class="idle-title">FUERA DE LLAMADA</div>
      <div id="idle-hint" class="idle-hint">Esperando la próxima conversación</div>
    </section>
    <div id="silence-dots" class="silence-dots hidden" aria-label="Canal en silencio">
      <span class="silence-dot"></span>
      <span class="silence-dot"></span>
      <span class="silence-dot"></span>
    </div>
  </div>
  <script>
    const target = document.getElementById("members");
    const idle = document.getElementById("idle");
    const idleTitle = document.getElementById("idle-title");
    const idleHint = document.getElementById("idle-hint");
    const silenceDots = document.getElementById("silence-dots");
    const loadedVersion = "__OVERLAY_VERSION__";
    const visible = new Map();
    const removalTimers = new Map();
    let last = "";

    function memberKey(member) {
      return member.avatar_url || "";
    }

    function createMember(member, key, slot) {
      const item = document.createElement("div");
      item.className = "member entering";
      item.style.setProperty("--slot", slot);

      const avatar = document.createElement("img");
      avatar.className = "avatar";
      avatar.alt = "";
      avatar.referrerPolicy = "no-referrer";
      avatar.src = member.avatar_url || "";
      item.append(avatar);
      target.append(item);
      visible.set(key, item);

      requestAnimationFrame(() => requestAnimationFrame(() => item.classList.remove("entering")));
      return item;
    }

    function removeMember(id, item) {
      if (item.classList.contains("leaving")) return;
      item.classList.add("leaving");
      const timer = setTimeout(() => {
        item.remove();
        visible.delete(id);
        removalTimers.delete(id);
      }, 400);
      removalTimers.set(id, timer);
    }

    function render(state) {
      const next = JSON.stringify(state);
      if (next === last) return;
      last = next;

      const speakers = (state.members || []).filter(member => member.speaking).slice(0, 3);
      const wanted = new Set(speakers.map(memberKey));
      const deafened = state.channel_id === "deafened";
      const connected = Boolean(state.channel_id);
      const hasCompany = (state.members || []).length > 0;
      const showLargeState = deafened || !connected || !hasCompany;
      const showSilenceDots = connected && hasCompany && !deafened && speakers.length === 0;

      target.classList.toggle("deafened", deafened);
      idle.classList.toggle("hidden", !showLargeState);
      silenceDots.classList.toggle("hidden", !showSilenceDots);
      if (deafened) {
        idleTitle.textContent = "AUDIO EN PAUSA";
        idleHint.textContent = "El anfitrión está ensordecido";
      } else if (!connected) {
        idleTitle.textContent = "FUERA DE LLAMADA";
        idleHint.textContent = "Esperando la próxima conversación";
      } else {
        idleTitle.textContent = "ESPERANDO COMPAÑÍA";
        idleHint.textContent = "Todavía no hay nadie más en la llamada";
      }

      for (const [id, item] of visible) {
        if (!wanted.has(id)) removeMember(id, item);
      }

      speakers.forEach((member, slot) => {
        const key = memberKey(member);
        let item = visible.get(key);
        if (!item) item = createMember(member, key, slot);

        const timer = removalTimers.get(key);
        if (timer) {
          clearTimeout(timer);
          removalTimers.delete(key);
          item.classList.remove("leaving");
        }

        item.style.setProperty("--slot", slot);
        const avatar = item.querySelector(".avatar");
        if (avatar.getAttribute("src") !== (member.avatar_url || "")) {
          avatar.src = member.avatar_url || "";
        }
      });
    }
    async function poll() {
      try { render(await (await fetch("/state", { cache: "no-store" })).json()); } catch (_) {}
    }
    async function reloadWhenUpdated() {
      try {
        const version = await (await fetch("/version", { cache: "no-store" })).text();
        if (version !== loadedVersion) location.reload();
      } catch (_) {}
    }
    poll(); setInterval(poll, 120);
    setInterval(reloadWhenUpdated, 1000);
  </script>
</body>
</html>
"""


GAMING_PAGE = """<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Equibop gaming voice overlay</title>
  <style>
    :root {
      color-scheme: dark;
      --avatar-size: 160px;
      --motion: 420ms cubic-bezier(.2, .82, .2, 1);
    }
    * { box-sizing: border-box; }
    html, body, #members { width: 100%; height: 100%; }
    body { margin: 0; overflow: hidden; background: transparent; }
    #members { position: relative; overflow: hidden; }
    .member {
      position: absolute;
      left: var(--x);
      bottom: var(--y);
      width: var(--avatar-size);
      height: var(--avatar-size);
      opacity: 1;
      transform: translateY(0);
      transition:
        left var(--motion), bottom var(--motion),
        transform var(--motion), opacity 220ms ease;
      will-change: left, bottom, transform, opacity;
    }
    .member.entering, .member.leaving {
      opacity: 0;
      transform: translateY(var(--exit-distance));
    }
    .avatar {
      display: block;
      width: 100%;
      height: 100%;
      border: 5px solid #23a55a;
      border-radius: 0;
      object-fit: cover;
      background: #2b2d31;
      box-shadow:
        0 10px 26px rgba(0, 0, 0, .46),
        0 0 0 3px rgba(35, 165, 90, .30);
      filter: grayscale(0) brightness(1);
      transition: filter 280ms ease, border-color 280ms ease, box-shadow 280ms ease;
    }
    #members.deafened .member:not(.entering):not(.leaving) { opacity: .30; }
    #members.deafened .avatar {
      filter: grayscale(1) brightness(.48);
      border-color: #777982;
      box-shadow: 0 9px 22px rgba(0, 0, 0, .30), 0 0 0 2px rgba(160, 162, 172, .16);
    }
    @media (prefers-reduced-motion: reduce) {
      .member { transition-duration: 1ms; }
    }
  </style>
</head>
<body>
  <div id="members"></div>
  <script>
    const target = document.getElementById("members");
    const loadedVersion = "__OVERLAY_VERSION__";
    const visible = new Map();
    const assignedSlots = new Map();
    const removalTimers = new Map();
    let positions = [];
    let avatarSize = 160;
    let last = "";

    function memberKey(member) {
      return member.avatar_url || "";
    }

    function shuffle(values) {
      for (let index = values.length - 1; index > 0; index--) {
        const other = Math.floor(Math.random() * (index + 1));
        [values[index], values[other]] = [values[other], values[index]];
      }
      return values;
    }

    function buildPositions(minimumCount = visible.size) {
      // Siempre se usa una única fila pegada al borde inferior. Diez huecos
      // conservan el aspecto disperso con llamadas normales; por encima de
      // eso los avatares se reducen para que nadie salte a una segunda fila.
      const slots = Math.max(10, minimumCount);
      const edge = 30;
      let gapX = slots <= 10 ? 24 : 18;
      avatarSize = Math.min(160, Math.floor((innerWidth - edge * 2 - gapX * (slots - 1)) / slots));
      avatarSize = Math.max(32, avatarSize);
      if (slots > 1 && avatarSize * slots + gapX * (slots - 1) > innerWidth - edge * 2) {
        gapX = Math.max(0, Math.floor((innerWidth - edge * 2 - avatarSize * slots) / (slots - 1)));
      }
      document.documentElement.style.setProperty("--avatar-size", `${avatarSize}px`);
      const gridWidth = slots * avatarSize + (slots - 1) * gapX;
      const startX = Math.max(edge, (innerWidth - gridWidth) / 2);
      const next = [];
      for (let slot = 0; slot < slots; slot++) {
        const jitterX = gapX >= 12 ? (Math.random() - .5) * 8 : 0;
        next.push({
          x: Math.round(startX + slot * (avatarSize + gapX) + jitterX),
          y: Math.round(16 + Math.random() * 8)
        });
      }
      positions = shuffle(next);
    }

    function freeSlot() {
      const occupied = new Set(assignedSlots.values());
      const available = positions
        .map((_position, slot) => slot)
        .filter(slot => !occupied.has(slot));
      if (!available.length) return -1;
      if (!occupied.size) {
        return available[Math.floor(Math.random() * available.length)];
      }

      // Escoge el punto cuya distancia al avatar más cercano sea mayor. Esto
      // conserva posiciones variables pero evita que los primeros hablantes
      // terminen agrupados en un extremo del lienzo.
      let bestDistance = -1;
      let best = [];
      for (const slot of available) {
        const distance = Math.min(...[...occupied].map(other =>
          Math.abs(positions[slot].x - positions[other].x)
        ));
        if (distance > bestDistance) {
          bestDistance = distance;
          best = [slot];
        } else if (distance === bestDistance) {
          best.push(slot);
        }
      }
      return best[Math.floor(Math.random() * best.length)];
    }

    function place(item, slot) {
      const position = positions[slot];
      if (!position) return false;
      item.style.setProperty("--x", `${position.x}px`);
      item.style.setProperty("--y", `${position.y}px`);
      item.style.setProperty("--exit-distance", `${position.y + avatarSize + 42}px`);
      item.style.zIndex = "1";
      return true;
    }

    function createMember(member, key) {
      let slot = freeSlot();
      if (slot < 0) {
        buildPositions(visible.size + 1);
        for (const [visibleKey, visibleItem] of visible) {
          place(visibleItem, assignedSlots.get(visibleKey));
        }
        slot = freeSlot();
      }
      if (slot < 0) return null;

      const item = document.createElement("div");
      item.className = "member entering";
      const avatar = document.createElement("img");
      avatar.className = "avatar";
      avatar.alt = "";
      avatar.referrerPolicy = "no-referrer";
      avatar.src = member.avatar_url || "";
      item.append(avatar);
      assignedSlots.set(key, slot);
      place(item, slot);
      target.append(item);
      visible.set(key, item);
      requestAnimationFrame(() => requestAnimationFrame(() => item.classList.remove("entering")));
      return item;
    }

    function removeMember(key, item) {
      if (item.classList.contains("leaving")) return;
      item.classList.add("leaving");
      const timer = setTimeout(() => {
        item.remove();
        visible.delete(key);
        assignedSlots.delete(key);
        removalTimers.delete(key);
      }, 460);
      removalTimers.set(key, timer);
    }

    function render(state) {
      const next = JSON.stringify(state);
      if (next === last) return;
      last = next;

      const speakers = (state.members || []).filter(member => member.speaking);
      const wanted = new Set(speakers.map(memberKey));
      target.classList.toggle("deafened", state.channel_id === "deafened");

      for (const [key, item] of visible) {
        if (!wanted.has(key)) removeMember(key, item);
      }

      speakers.forEach(member => {
        const key = memberKey(member);
        let item = visible.get(key);
        if (!item) item = createMember(member, key);
        if (!item) return;

        const timer = removalTimers.get(key);
        if (timer) {
          clearTimeout(timer);
          removalTimers.delete(key);
          item.classList.remove("leaving");
        }
        const avatar = item.querySelector(".avatar");
        if (avatar.getAttribute("src") !== (member.avatar_url || "")) {
          avatar.src = member.avatar_url || "";
        }
      });
    }

    async function poll() {
      try { render(await (await fetch("/state", { cache: "no-store" })).json()); } catch (_) {}
    }

    async function reloadWhenUpdated() {
      try {
        const version = await (await fetch("/version", { cache: "no-store" })).text();
        if (version !== loadedVersion) location.reload();
      } catch (_) {}
    }

    buildPositions();
    addEventListener("resize", () => {
      buildPositions(visible.size);
      for (const [key, item] of visible) place(item, assignedSlots.get(key));
    });
    poll(); setInterval(poll, 120);
    setInterval(reloadWhenUpdated, 1000);
  </script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def send_content(self, body: bytes, content_type: str) -> None:
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/":
            page = PAGE.replace("__OVERLAY_VERSION__", OVERLAY_VERSION)
            self.send_content(page.encode("utf-8"), "text/html; charset=utf-8")
        elif path in {"/jugando", "/gaming"}:
            page = GAMING_PAGE.replace("__OVERLAY_VERSION__", OVERLAY_VERSION)
            self.send_content(page.encode("utf-8"), "text/html; charset=utf-8")
        elif path == "/state":
            self.send_content(json.dumps(read_state(), separators=(",", ":")).encode("utf-8"), "application/json")
        elif path == "/version":
            self.send_content(OVERLAY_VERSION.encode("utf-8"), "text/plain; charset=utf-8")
        else:
            self.send_error(HTTPStatus.NOT_FOUND)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
