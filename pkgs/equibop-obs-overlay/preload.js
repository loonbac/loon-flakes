// Puente mínimo renderer -> proceso principal. No expone acceso a Node ni IPC
// genérico a Discord: sólo admite publicar el estado ya saneado del overlay.
try {
  const { contextBridge, ipcRenderer } = require("electron");
  contextBridge.exposeInMainWorld("EquibopObsOverlay", {
    publish(value) {
      ipcRenderer.send("equibop-obs-overlay:publish", value);
    }
  });
} catch (_) {}
