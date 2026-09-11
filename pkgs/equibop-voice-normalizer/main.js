// Puente local y recarga en vivo para el normalizador de voces de Equibop.
(() => {
  const { app, ipcMain } = require("electron");
  const fs = require("fs");
  const path = require("path");
  const runtimeDir = process.env.XDG_RUNTIME_DIR || `/tmp/equibop-normalizer-${process.getuid?.() || 0}`;
  const stateDir = path.join(runtimeDir, "equibop-voice-normalizer");
  const stateFile = path.join(stateDir, "state.json");

  function finite(value, fallback = null) {
    return Number.isFinite(value) ? Math.round(value * 10) / 10 : fallback;
  }

  function sanitize(value) {
    const participants = Array.isArray(value?.participants)
      ? value.participants.slice(0, 50).map(participant => ({
          speaking: Boolean(participant?.speaking),
          raw_activity: finite(participant?.raw_activity),
          voice_db: finite(participant?.voice_db),
          measured_db: finite(participant?.measured_db),
          volume: finite(participant?.volume),
          samples: Math.max(0, Math.min(100, Number(participant?.samples) || 0))
        }))
      : [];
    return {
      ready: Boolean(value?.ready),
      active: Boolean(value?.active),
      enabled: Boolean(value?.enabled),
      target_db: finite(value?.target_db, -24),
      participants
    };
  }

  ipcMain.on("equibop-voice-normalizer:publish", (_event, value) => {
    try {
      fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
      const temporary = `${stateFile}.${process.pid}.tmp`;
      fs.writeFileSync(temporary, JSON.stringify(sanitize(value)), { encoding: "utf8", mode: 0o600 });
      fs.renameSync(temporary, stateFile);
    } catch (_) {}
  });

  const bundledRendererPath = path.join(__dirname, "voice-normalizer-renderer.js");
  const liveRendererPath = "/run/current-system/sw/share/equibop-voice-normalizer/renderer.js";

  function readRendererScript() {
    try { return fs.readFileSync(liveRendererPath, "utf8"); } catch (_) {}
    try { return fs.readFileSync(bundledRendererPath, "utf8"); } catch (_) {}
    return "";
  }

  const reloadTimers = new WeakMap();
  app.on("web-contents-created", (_event, contents) => {
    contents.on("did-finish-load", () => {
      if (!contents.getURL().startsWith("https://discord.com/")) return;

      const previousTimer = reloadTimers.get(contents);
      if (previousTimer) clearInterval(previousTimer);
      let installedScript = readRendererScript();
      if (installedScript) contents.executeJavaScript(installedScript, true).catch(() => {});

      const reloadTimer = setInterval(() => {
        if (contents.isDestroyed()) return clearInterval(reloadTimer);
        const nextScript = readRendererScript();
        if (!nextScript || nextScript === installedScript) return;
        installedScript = nextScript;
        contents.executeJavaScript(nextScript, true).catch(() => {});
      }, 1000);
      reloadTimers.set(contents, reloadTimer);
      contents.once("destroyed", () => clearInterval(reloadTimer));
    });
  });
})();
