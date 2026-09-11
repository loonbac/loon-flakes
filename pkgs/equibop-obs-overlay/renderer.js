// Ejecutado dentro de Discord. Sólo lee los stores que ya usa la interfaz y
// publica una representación mínima para el overlay local.
(() => {
  try { window.__equibopObsOverlayStop?.(); } catch (_) {}
  window.__equibopObsOverlayInstalled = true;
  let publishTimer = null;
  let bootTimer = null;

  function modules() {
    const chunks = window.webpackChunkdiscord_app;
    if (!chunks) return [];
    let require;
    chunks.push([[`equibop_obs_${Date.now()}`], {}, value => { require = value; }]);
    chunks.pop();
    return require ? Object.values(require.c).flatMap(module => [module.exports, module.exports?.default]).filter(Boolean) : [];
  }

  function find(items, predicate) {
    return items.find(item => {
      try { return predicate(item); } catch (_) { return false; }
    });
  }

  function avatarUrl(user) {
    if (typeof user.getAvatarURL === "function") {
      try { return user.getAvatarURL(null, 128, true); } catch (_) {}
    }
    return user.avatar ? `https://cdn.discordapp.com/avatars/${user.id}/${user.avatar}.png?size=128` : "";
  }

  function start() {
    const items = modules();
    const common = window.Vencord?.Webpack?.Common;
    const users = common?.UserStore || find(items, item => typeof item.getCurrentUser === "function" && typeof item.getUser === "function");
    const voices = common?.VoiceStateStore || find(items, item => typeof item.getVoiceStatesForChannel === "function" || typeof item.getAllVoiceStates === "function");
    const selected = common?.SelectedChannelStore;
    const mediaEngine = common?.MediaEngineStore || find(items, item => typeof item.isSelfDeaf === "function");
    const channelRtc = common?.ChannelRTCStore || find(items, item => typeof item.getSpeakingParticipants === "function");
    const legacySpeaking = find(items, item => typeof item.isSpeaking === "function");
    const bridge = window.EquibopObsOverlay;
    if (!bridge) return false;

    // Señal de vida privada: permite distinguir un puente cargado de un
    // Discord aún no listo, sin incluir datos de la cuenta ni del canal.
    bridge.publish({ channel_id: null, members: [] });
    if (!users || !voices) return false;

    function isSpeaking(userId, channelId) {
      try {
        const participants = channelRtc?.getSpeakingParticipants?.(channelId) || [];
        const participant = participants.find(value =>
          (value?.user?.id || value?.userId || value?.id) === userId
        );
        if (participant) return Boolean(participant.speaking ?? true);
      } catch (_) {}

      if (legacySpeaking) {
        for (const args of [[userId], [channelId, userId], [userId, channelId]]) {
          try {
            const value = legacySpeaking.isSpeaking(...args);
            if (value === true) return true;
          } catch (_) {}
        }
      }
      return false;
    }

    function publish() {
      try {
        const current = users.getCurrentUser();
        const all = typeof voices.getAllVoiceStates === "function"
          ? Object.values(voices.getAllVoiceStates() || {}).flatMap(group => Object.values(group || {}))
          : [];
        const mine = all.find(state => state?.userId === current?.id && state?.channelId);
        const channelId = selected?.getVoiceChannelId?.() || mine?.channelId;
        const deafened = Boolean(mediaEngine?.isSelfDeaf?.() || mine?.deaf || mine?.selfDeaf);
        const channelStates = channelId && typeof voices.getVoiceStatesForChannel === "function"
          ? Object.values(voices.getVoiceStatesForChannel(channelId) || {})
          : all.filter(state => state?.channelId === channelId);
        const members = channelId ? channelStates.filter(state => state?.userId !== current?.id).map(state => {
          const user = users.getUser(state.userId);
          if (!user) return null;
          return {
            avatar_url: avatarUrl(user),
            speaking: isSpeaking(user.id, channelId)
          };
        }).filter(Boolean) : [];
        // El marcador no expone el ID del canal; sólo permite que el overlay
        // distinga el estado ensordecido sin ampliar el puente IPC.
        bridge.publish({ channel_id: deafened ? "deafened" : (channelId || null), members });
      } catch (_) {}
    }

    publish();
    publishTimer = window.setInterval(publish, 200);
    return true;
  }

  let attempts = 0;
  bootTimer = window.setInterval(() => {
    if (start() || ++attempts >= 120) {
      window.clearInterval(bootTimer);
      bootTimer = null;
    }
  }, 250);

  window.__equibopObsOverlayStop = () => {
    if (bootTimer) window.clearInterval(bootTimer);
    if (publishTimer) window.clearInterval(publishTimer);
    bootTimer = null;
    publishTimer = null;
  };
})();
