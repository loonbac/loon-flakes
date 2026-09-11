// Sólo permite publicar métricas saneadas al proceso principal. No expone IPC
// genérico, Node ni contenido de Discord al renderer.
try {
  const { contextBridge, ipcRenderer } = require("electron");
  contextBridge.exposeInMainWorld("EquibopVoiceNormalizer", {
    publish(value) {
      ipcRenderer.send("equibop-voice-normalizer:publish", value);
    }
  });
} catch (_) {}
