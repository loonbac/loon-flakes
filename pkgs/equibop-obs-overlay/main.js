// Complemento local de OBS para Equibop. Se ejecuta en el proceso principal,
// valida los datos que recibe del renderer y los deja en el runtime privado.
(() => {
  const { app, ipcMain } = require("electron");
  const fs = require("fs");
  const path = require("path");
  const runtimeDir = process.env.XDG_RUNTIME_DIR || `/tmp/equibop-obs-${process.getuid?.() || 0}`;
  const stateDir = path.join(runtimeDir, "equibop-obs-overlay");
  const stateFile = path.join(stateDir, "state.json");

  function string(value, limit = 256) {
    return typeof value === "string" ? value.slice(0, limit) : "";
  }

  function sanitize(value) {
    const members = Array.isArray(value?.members) ? value.members.slice(0, 50).map(member => ({
      avatar_url: string(member?.avatar_url, 512),
      speaking: Boolean(member?.speaking)
    })).filter(member => member.avatar_url) : [];
    return { channel_id: string(value?.channel_id, 32) || null, members };
  }

  ipcMain.on("equibop-obs-overlay:publish", (_event, value) => {
    try {
      fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
      const temporary = `${stateFile}.${process.pid}.tmp`;
      fs.writeFileSync(temporary, JSON.stringify(sanitize(value)), { encoding: "utf8", mode: 0o600 });
      fs.renameSync(temporary, stateFile);
    } catch (_) {}
  });

  const bundledRendererPath = path.join(__dirname, "obs-overlay-renderer.js");
  const liveRendererPath = "/run/current-system/sw/share/equibop-obs-overlay/renderer.js";

  function readRendererScript() {
    try { return fs.readFileSync(liveRendererPath, "utf8"); } catch (_) {}
    try { return fs.readFileSync(bundledRendererPath, "utf8"); } catch (_) {}
    return "";
  }

  const reloadTimers = new WeakMap();
  app.on("web-contents-created", (_event, contents) => {
    contents.on("did-finish-load", () => {
      if (contents.getURL().startsWith("https://discord.com/")) {
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
      }
    });
  });
})();
