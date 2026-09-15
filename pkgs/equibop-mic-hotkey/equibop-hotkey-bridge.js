// Puente local de baja latencia para los hotkeys de voz de Equibop.
// Se ejecuta en el proceso principal de Electron y recibe sólo conexiones al
// socket privado del usuario. Evita arrancar una segunda instancia de Electron
// para cada pulsación del Basilisk.
(() => {
  if (process.platform !== "linux") return;

  const { app, BrowserWindow } = require("electron");
  const fs = require("fs");
  const net = require("net");
  const os = require("os");
  const path = require("path");

  const socketPath = path.join(process.env.XDG_RUNTIME_DIR || os.tmpdir(), "equibop-hotkey.sock");
  const events = {
    mute: "VCD_TOGGLE_SELF_MUTE",
    deafen: "VCD_TOGGLE_SELF_DEAF",
  };

  const removeSocket = () => {
    try {
      fs.unlinkSync(socketPath);
    } catch (error) {
      if (error.code !== "ENOENT") console.error("Equibop hotkey socket cleanup failed:", error);
    }
  };

  const sendToRenderer = command => {
    const event = events[command];
    if (!event) return false;

    let sent = false;
    for (const window of BrowserWindow.getAllWindows()) {
      if (!window.isDestroyed() && !window.webContents.isDestroyed()) {
        window.webContents.send(event);
        sent = true;
      }
    }
    return sent;
  };

  app.whenReady().then(() => {
    removeSocket();
    const server = net.createServer(connection => {
      connection.setEncoding("utf8");
      connection.setTimeout(1000);
      connection.once("data", data => {
        const sent = sendToRenderer(data.trim());
        connection.end(sent ? "ok\n" : "not-ready\n");
      });
      connection.on("timeout", () => connection.destroy());
      connection.on("error", () => {});
    });

    server.on("error", error => console.error("Equibop hotkey socket failed:", error));
    server.listen(socketPath, () => {
      try {
        fs.chmodSync(socketPath, 0o600);
      } catch (error) {
        console.error("Equibop hotkey socket permission change failed:", error);
      }
    });

    app.once("will-quit", () => {
      server.close();
      removeSocket();
    });
  });
})();
