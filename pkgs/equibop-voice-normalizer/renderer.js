// Normalizador local por participante. Usa los niveles de recepción calculados
// por el motor de Discord y su control local por usuario; ningún audio sale del equipo.
(() => {
  try { window.__equibopVoiceNormalizerStop?.(); } catch (_) {}

  const CONFIG = Object.freeze({
    noiseGateDb: -55,
    minVolume: 5,
    maxVolume: 800,
    minimumSamples: 4,
    sampleWindow: 12,
    percentile: 0.7,
    intervalMs: 100,
    applyEveryMs: 100,
    quietHoldMs: 1600,
    boostStepDb: 1.2,
    cutStepDb: 3
  });
  const STORAGE_KEY = "equibop.voiceNormalizer.config.v1";
  const runtimeConfig = { enabled: true, targetDb: -24, position: null };
  const audio = createNormalizerAudio();

  try {
    const saved = JSON.parse(window.localStorage.getItem(STORAGE_KEY) || "{}");
    if (typeof saved.enabled === "boolean") runtimeConfig.enabled = saved.enabled;
    if (Number.isFinite(saved.targetDb)) runtimeConfig.targetDb = clamp(saved.targetDb, -36, -12);
    if (Number.isFinite(saved.position?.x) && Number.isFinite(saved.position?.y)) {
      runtimeConfig.position = saved.position;
    }
  } catch (_) {}

  const states = new Map();
  const activityLevels = new Map();
  const statsLevels = new Map();
  let bootTimer = null;
  let controlTimer = null;
  let publishTimer = null;
  let stores = null;
  let controlHost = null;
  let controlButton = null;
  let controlTarget = null;
  let documentClickHandler = null;
  let resizeHandler = null;
  let controlStatus = null;
  let nativeMediaEngine = null;
  let voiceActivityHandler = null;
  let statsPollRunning = false;
  let lastStatsPollAt = 0;

  function clamp(value, minimum, maximum) {
    return Math.min(maximum, Math.max(minimum, value));
  }

  function webpackModules() {
    const chunks = window.webpackChunkdiscord_app;
    if (!chunks) return [];
    let webpackRequire;
    chunks.push([[`equibop_normalizer_${Date.now()}`], {}, value => { webpackRequire = value; }]);
    chunks.pop();
    return webpackRequire
      ? Object.values(webpackRequire.c)
          .flatMap(module => [module.exports, module.exports?.default])
          .filter(Boolean)
      : [];
  }

  function find(items, predicate) {
    return items.find(item => {
      try { return predicate(item); } catch (_) { return false; }
    });
  }

  function locateStores() {
    const common = window.Vencord?.Webpack?.Common;
    const items = webpackModules();
    const users = common?.UserStore
      || find(items, item => typeof item.getCurrentUser === "function" && typeof item.getUser === "function");
    const voices = common?.VoiceStateStore
      || find(items, item => typeof item.getVoiceStatesForChannel === "function" && typeof item.getAllVoiceStates === "function");
    const selected = common?.SelectedChannelStore
      || find(items, item => typeof item.getVoiceChannelId === "function");
    const media = common?.MediaEngineStore
      || find(items, item => typeof item.getMediaEngine === "function" && typeof item.getLocalVolume === "function");
    const dispatcher = common?.FluxDispatcher
      || find(items, item => typeof item.dispatch === "function" && typeof item.subscribe === "function");
    // Discord separa las lecturas (Store) de las mutaciones (Actions).
    let mediaActions = null;
    try {
      mediaActions = window.Vencord?.Webpack?.findByProps?.("setLocalVolume", "setLocalMute");
    } catch (_) {}
    mediaActions ||= find(items, item =>
      typeof item.setLocalVolume === "function" && typeof item.setLocalMute === "function"
    ) || find(items, item => typeof item.setLocalVolume === "function");
    const rtc = common?.ChannelRTCStore
      || find(items, item => typeof item.getParticipants === "function" && typeof item.getSpeakingParticipants === "function");
    return users && voices && media && rtc
      ? { users, voices, selected, media, mediaActions, dispatcher, rtc }
      : null;
  }

  function voiceChannelId() {
    try {
      const selectedId = stores.selected?.getVoiceChannelId?.();
      if (selectedId) return selectedId;
      const currentId = stores.users.getCurrentUser()?.id;
      const groups = stores.voices.getAllVoiceStates?.() || {};
      const all = Object.values(groups).flatMap(group => Object.values(group || {}));
      return all.find(state => state?.userId === currentId && state?.channelId)?.channelId || null;
    } catch (_) {
      return null;
    }
  }

  function percentile(samples) {
    const sorted = [...samples].sort((left, right) => left - right);
    const index = Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * CONFIG.percentile));
    return sorted[index];
  }

  function desiredVolume(measuredDb, maximum = CONFIG.maxVolume) {
    const gainDb = runtimeConfig.targetDb - measuredDb;
    return clamp(100 * Math.pow(10, gainDb / 20), CONFIG.minVolume, maximum);
  }

  function activityToDb(value) {
    if (!Number.isFinite(value)) return null;
    if (value === 0) return -100;
    if (value < 0) return clamp(value, -100, 0);
    // Algunas versiones entregan amplitud lineal 0..1 en vez de dBFS.
    if (value <= 1) return clamp(20 * Math.log10(Math.max(value, 0.00001)), -100, 0);
    return null;
  }

  function ensureVoiceActivity() {
    try {
      const nextMediaEngine = stores.media.getMediaEngine?.();
      if (nextMediaEngine === nativeMediaEngine && voiceActivityHandler) return;
      detachVoiceActivity();
      nativeMediaEngine = nextMediaEngine;
      if (!nativeMediaEngine || typeof nativeMediaEngine.on !== "function") return;
      voiceActivityHandler = (userId, value) => {
        if (typeof userId !== "string" || !Number.isFinite(value)) return;
        activityLevels.set(userId, { value, at: Date.now() });
      };
      nativeMediaEngine.on("VoiceActivity", voiceActivityHandler);
    } catch (_) {
      nativeMediaEngine = null;
      voiceActivityHandler = null;
    }
  }

  function detachVoiceActivity() {
    try {
      if (nativeMediaEngine && voiceActivityHandler) {
        if (typeof nativeMediaEngine.off === "function") {
          nativeMediaEngine.off("VoiceActivity", voiceActivityHandler);
        } else if (typeof nativeMediaEngine.removeListener === "function") {
          nativeMediaEngine.removeListener("VoiceActivity", voiceActivityHandler);
        }
      }
    } catch (_) {}
    nativeMediaEngine = null;
    voiceActivityHandler = null;
    activityLevels.clear();
  }

  function statsValueToDb(key, value) {
    if (!Number.isFinite(value)) return null;
    const name = String(key || "").toLowerCase();
    if (!/(audio.*level|level.*audio|voice.*level|rms)/.test(name)) return null;
    if (value >= 0 && value <= 1) {
      return value === 0 ? -100 : clamp(20 * Math.log10(value), -100, 0);
    }
    if (value >= -100 && value <= 0) return value;
    // RFC 6464 representa el nivel como atenuación positiva de 0 a 127 dB.
    if (value > 1 && value <= 127 && /(level|rms)/.test(name)) return clamp(-value, -100, 0);
    return null;
  }

  function collectStatsLevels(connection, value, inheritedUserId = null, depth = 0) {
    if (!value || depth > 8) return;
    if (Array.isArray(value)) {
      for (const item of value) collectStatsLevels(connection, item, inheritedUserId, depth + 1);
      return;
    }
    if (typeof value !== "object") return;

    let userId = inheritedUserId;
    for (const key of ["userId", "user_id", "userid"]) {
      if (typeof value[key] === "string") userId = value[key];
    }
    if (!userId) {
      const ssrc = value.ssrc ?? value.audioSsrc ?? value.audio_ssrc;
      if (Number.isFinite(Number(ssrc)) && typeof connection?.getUserIdBySsrc === "function") {
        try {
          const resolved = connection.getUserIdBySsrc(Number(ssrc));
          if (typeof resolved === "string") userId = resolved;
        } catch (_) {}
      }
    }

    if (userId) {
      for (const [key, candidate] of Object.entries(value)) {
        const db = statsValueToDb(key, candidate);
        if (db !== null) {
          statsLevels.set(userId, { value: candidate, db, at: Date.now() });
          break;
        }
      }
    }
    for (const child of Object.values(value)) {
      if (child && typeof child === "object") {
        collectStatsLevels(connection, child, userId, depth + 1);
      }
    }
  }

  async function pollConnectionStats(now) {
    if (statsPollRunning || now - lastStatsPollAt < 400) return;
    lastStatsPollAt = now;
    const connections = [...(nativeMediaEngine?.connections || [])];
    if (!connections.length) return;
    statsPollRunning = true;
    try {
      for (const connection of connections) {
        if (typeof connection?.getStats !== "function") continue;
        try {
          const stats = await connection.getStats();
          collectStatsLevels(connection, stats);
        } catch (_) {}
      }
    } finally {
      statsPollRunning = false;
    }
  }

  function saveConfig() {
    try { window.localStorage.setItem(STORAGE_KEY, JSON.stringify(runtimeConfig)); } catch (_) {}
  }

  function setUserVolume(userId, volume) {
    // La acción pública además sincroniza preferencias remotas. El evento local
    // actualiza Store y motor sin guardar cada paso automático en Discord.
    if (typeof stores?.dispatcher?.dispatch === "function") {
      stores.dispatcher.dispatch({
        type: "AUDIO_SET_LOCAL_VOLUME",
        userId,
        volume,
        context: "default"
      });
      return;
    }
    if (typeof stores?.mediaActions?.setLocalVolume === "function") {
      stores.mediaActions.setLocalVolume(userId, volume);
      return;
    }
    throw new Error("No está disponible la acción de volumen de Discord");
  }

  function getUserVolume(userId) {
    const stored = stores?.media?.getLocalVolume?.(userId);
    if (Number.isFinite(stored)) return stored;
    const connections = [...(stores?.media?.getMediaEngine?.()?.connections || [])];
    const connection = connections.find(item => item?.context === "default")
      || connections.find(item => typeof item?.getLocalVolume === "function");
    if (connection && typeof connection.getLocalVolume === "function") {
      const value = connection.getLocalVolume(userId);
      if (Number.isFinite(value)) return value;
    }
    return null;
  }

  function restoreAll() {
    for (const [userId, state] of states) restore(userId, state);
    states.clear();
    audio.stop();
  }

  function updateControl(inCall = Boolean(voiceChannelId())) {
    if (!controlHost) return;
    controlHost.style.display = inCall ? "block" : "none";
    if (controlButton) {
      controlButton.textContent = `${runtimeConfig.enabled ? ([...states.values()].some(state => state.realtime) ? "Nϟ" : "N") : "N×"} ${runtimeConfig.targetDb} dB`;
      controlButton.dataset.enabled = String(runtimeConfig.enabled);
    }
    if (controlTarget) controlTarget.textContent = `${runtimeConfig.targetDb} dB`;
    if (controlStatus) {
      const values = [...states.values()];
      const measured = values.filter(state => state.speaking);
      const limited = values.filter(state => state.speaking && state.appliedVolume >= (state.audioRoute ? CONFIG.maxVolume : 200));
      controlStatus.textContent = !runtimeConfig.enabled ? "Pausado"
        : measured.length ? `${measured.length} ${measured.length === 1 ? "voz" : "voces"} · ${values.filter(state => state.realtime).length} en tiempo real${limited.length ? " · ganancia máxima alcanzada" : ""}`
        : "Esperando voz";
      const errors = values.some(state => state.error);
      if (errors) controlStatus.textContent = "No se pudo aplicar el ajuste de audio";
    }
  }

  function createControl() {
    controlHost?.remove();
    controlHost = document.createElement("div");
    controlHost.id = "equibop-voice-normalizer-control";
    controlHost.style.cssText = "position:fixed;width:max-content;left:8px;bottom:90px;z-index:10000;display:none";
    const shadow = controlHost.attachShadow({ mode: "open" });
    shadow.innerHTML = `
      <style>
        :host { color-scheme: dark; font: 13px/1.35 system-ui, sans-serif; }
        button, input { font: inherit; }
        #toggle, #move {
          border: 1px solid #5d6070; border-radius: 7px; padding: 6px 9px;
          color: #fff; background: #2b2d31; cursor: pointer;
          box-shadow: 0 3px 12px #0008;
        }
        #toggle[data-enabled="true"] { border-color: #7ca2e0; color: #dce8ff; }
        #move { cursor: grab; touch-action: none; user-select: none; padding-inline: 6px; }
        #move:active { cursor: grabbing; }
        #panel {
          display: none; position: fixed; width: min(250px, calc(100vw - 16px)); max-height: calc(100vh - 16px); overflow: auto;
          box-sizing: border-box; padding: 12px; border: 1px solid #4e5058;
          border-radius: 9px; background: #1e1f22; color: #dbdee1;
          box-shadow: 0 8px 28px #000a;
        }
        #panel.open { display: block; }
        .title { margin-bottom: 9px; color: #f2f3f5; font-weight: 650; }
        .row { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
        .range { margin-top: 11px; }
        .range label { display: flex; justify-content: space-between; margin-bottom: 5px; }
        input[type="range"] { width: 100%; accent-color: #7ca2e0; }
        .hint { margin-top: 7px; color: #949ba4; font-size: 11px; }
      </style>
      <button id="move" type="button" aria-label="Mover normalizador; usa las flechas o arrastra" title="Arrastra para mover; también puedes usar las flechas">⠿</button>
      <button id="toggle" type="button" aria-expanded="false" aria-label="Configurar normalizador de voz"></button>
      <section id="panel" aria-label="Normalizador de voz">
        <div class="title">Normalizador por usuario</div>
        <label class="row"><span>Activado</span><input id="enabled" type="checkbox"></label>
        <div class="range">
          <label for="target"><span>Nivel objetivo</span><strong id="targetValue"></strong></label>
          <input id="target" type="range" min="-36" max="-12" step="1">
        </div>
        <div class="hint">Más cerca de −12 dB suena más fuerte. El ajuste se guarda localmente.</div>
        <div class="hint" id="status" role="status"></div>
      </section>`;

    controlButton = shadow.getElementById("toggle");
    controlTarget = shadow.getElementById("targetValue");
    controlStatus = shadow.getElementById("status");
    const panel = shadow.getElementById("panel");
    const move = shadow.getElementById("move");
    const enabled = shadow.getElementById("enabled");
    const target = shadow.getElementById("target");
    enabled.checked = runtimeConfig.enabled;
    target.value = String(runtimeConfig.targetDb);

    const placePanel = () => {
      const rect = controlHost.getBoundingClientRect();
      panel.style.left = `${clamp(rect.left, 8, Math.max(8, window.innerWidth - panel.offsetWidth - 8))}px`;
      const above = rect.top - panel.offsetHeight - 8;
      panel.style.top = `${clamp(above >= 8 ? above : rect.bottom + 8, 8, Math.max(8, window.innerHeight - panel.offsetHeight - 8))}px`;
    };
    const place = (x, y) => {
      const rect = controlHost.getBoundingClientRect();
      runtimeConfig.position = {
        x: clamp(x, 8, Math.max(8, window.innerWidth - rect.width - 8)),
        y: clamp(y, 8, Math.max(8, window.innerHeight - rect.height - 8))
      };
      controlHost.style.left = `${runtimeConfig.position.x}px`;
      controlHost.style.top = `${runtimeConfig.position.y}px`;
      controlHost.style.bottom = "auto";
      placePanel();
    };
    let drag = null;
    move.addEventListener("pointerdown", event => {
      if (event.button !== 0) return;
      const rect = controlHost.getBoundingClientRect();
      drag = { x: event.clientX - rect.left, y: event.clientY - rect.top };
      move.setPointerCapture(event.pointerId);
      event.preventDefault();
    });
    move.addEventListener("pointermove", event => {
      if (drag) place(event.clientX - drag.x, event.clientY - drag.y);
    });
    const endDrag = () => { if (drag) saveConfig(); drag = null; };
    move.addEventListener("pointerup", endDrag);
    move.addEventListener("pointercancel", endDrag);
    move.addEventListener("lostpointercapture", endDrag);
    move.addEventListener("keydown", event => {
      const delta = { ArrowLeft: [-10, 0], ArrowRight: [10, 0], ArrowUp: [0, -10], ArrowDown: [0, 10] }[event.key];
      if (!delta) return;
      event.preventDefault();
      const rect = controlHost.getBoundingClientRect();
      place(rect.left + delta[0], rect.top + delta[1]);
      saveConfig();
    });
    resizeHandler = () => {
      if (runtimeConfig.position) place(runtimeConfig.position.x, runtimeConfig.position.y);
      else placePanel();
    };
    window.addEventListener("resize", resizeHandler);

    controlButton.addEventListener("click", event => {
      event.stopPropagation();
      panel.classList.toggle("open");
      controlButton.setAttribute("aria-expanded", String(panel.classList.contains("open")));
      placePanel();
    });
    enabled.addEventListener("change", () => {
      runtimeConfig.enabled = enabled.checked;
      if (!runtimeConfig.enabled) restoreAll();
      saveConfig();
      updateControl();
    });
    target.addEventListener("input", () => {
      runtimeConfig.targetDb = clamp(Number(target.value), -36, -12);
      saveConfig();
      updateControl();
    });
    documentClickHandler = event => {
      if (!event.composedPath().includes(controlHost)) {
        panel.classList.remove("open");
        controlButton.setAttribute("aria-expanded", "false");
      }
    };
    document.addEventListener("click", documentClickHandler);
    document.documentElement.appendChild(controlHost);
    updateControl();
    resizeHandler();
  }

  function restore(userId, state) {
    try {
      const current = getUserVolume(userId);
      if (Number.isFinite(current) && Math.abs(current - state.appliedVolume) <= 2) {
        setUserVolume(userId, state.originalVolume);
      }
    } catch (_) {}
  }

  function tick() {
    ensureVoiceActivity();
    const channelId = voiceChannelId();
    updateControl(Boolean(channelId));
    if (!runtimeConfig.enabled) return;
    const currentId = stores.users.getCurrentUser()?.id;
    const now = Date.now();
    void pollConnectionStats(now);
    const seen = new Set();
    const connections = [...(nativeMediaEngine?.connections || [])];
    let channelStates = [];
    let rtcParticipants = [];
    let speakingParticipants = [];
    try {
      channelStates = channelId
        ? Object.values(stores.voices.getVoiceStatesForChannel(channelId) || {})
        : [];
    } catch (_) {}
    try { rtcParticipants = channelId ? stores.rtc.getParticipants(channelId) || [] : []; } catch (_) {}
    try { speakingParticipants = channelId ? stores.rtc.getSpeakingParticipants(channelId) || [] : []; } catch (_) {}

    const rtcByUser = new Map();
    for (const participant of [...rtcParticipants, ...speakingParticipants]) {
      const userId = participant?.user?.id || participant?.userId || participant?.id;
      if (userId) rtcByUser.set(userId, participant);
    }

    // VoiceStateStore es la fuente autoritativa de membresía (la misma que usa
    // el overlay). ChannelRTCStore puede devolver una lista visual vacía según
    // el layout, pero conserva las métricas de quienes están hablando.
    for (const voiceState of channelStates) {
      const userId = voiceState?.userId;
      if (!userId || userId === currentId) continue;
      seen.add(userId);

      let participant = rtcByUser.get(userId);
      if (!participant && channelId && typeof stores.rtc.getParticipant === "function") {
        try { participant = stores.rtc.getParticipant(channelId, userId); } catch (_) {}
      }

      let state = states.get(userId);
      if (!state) {
        let originalVolume = 100;
        try { originalVolume = getUserVolume(userId); } catch (_) {}
        if (!Number.isFinite(originalVolume)) originalVolume = 100;
        state = {
          originalVolume,
          appliedVolume: originalVolume,
          measuredDb: null,
          voiceDb: null,
          rawActivity: null,
          samples: [],
          lastVoiceAt: 0,
          lastApplyAt: 0,
          speaking: false
        };
        states.set(userId, state);
      }

      // Discord puede usar -Infinity para silencio absoluto. Se conserva el
      // participante y se trata como silencio para no perder la ventana entre
      // una frase y la siguiente ni restaurar su volumen prematuramente.
      const nativeActivity = activityLevels.get(userId);
      const statsActivity = statsLevels.get(userId);
      const activity = statsActivity && now - statsActivity.at <= CONFIG.quietHoldMs
        ? statsActivity
        : nativeActivity;
      state.rawActivity = activity?.value ?? null;
      const eventDb = activity && now - activity.at <= CONFIG.quietHoldMs
        ? (Number.isFinite(activity.db) ? activity.db : activityToDb(activity.value))
        : null;
      let direct = null;
      try { direct = audio.measure(connections, userId, runtimeConfig.targetDb); state.error = null; }
      catch (_) { state.error = "audio"; }
      state.audioRoute = Boolean(direct);
      state.realtime = Boolean(direct?.realtime);
      const voiceDb = direct ? direct.db : Number.isFinite(participant?.voiceDb)
        ? clamp(participant.voiceDb, -100, 0)
        : (eventDb ?? -100);
      const recentlyActive = Boolean(activity && now - activity.at <= 350);
      const speaking = Boolean(
        direct ? direct.db >= CONFIG.noiseGateDb : participant?.speaking
        || rtcByUser.has(userId) && speakingParticipants.includes(participant)
        || recentlyActive
      )
        && voiceDb >= CONFIG.noiseGateDb;
      state.voiceDb = voiceDb;
      state.speaking = speaking;

      if (speaking) {
        if (now - state.lastVoiceAt > CONFIG.quietHoldMs) state.samples = [];
        state.lastVoiceAt = now;
        state.samples.push(voiceDb);
        if (state.samples.length > CONFIG.sampleWindow) state.samples.shift();
        state.measuredDb = direct?.realtime ? voiceDb : percentile(state.samples);
      }

      if (!direct?.realtime && (
        state.samples.length < CONFIG.minimumSamples
        || now - state.lastVoiceAt > CONFIG.quietHoldMs
        || now - state.lastApplyAt < CONFIG.applyEveryMs
      )) continue;

      let target = desiredVolume(state.measuredDb, state.audioRoute ? CONFIG.maxVolume : 200);
      // Pasos en dB: convergencia independiente del porcentaje inicial. Reduce
      // voces fuertes más rápido de lo que amplifica voces bajas.
      const current = Math.max(CONFIG.minVolume, state.appliedVolume);
      const deltaDb = clamp(20 * Math.log10(target / current), -CONFIG.cutStepDb, CONFIG.boostStepDb);
      target = Math.round(current * Math.pow(10, deltaDb / 20) * 10) / 10;
      if (direct?.realtime) target = Math.round(direct.gain * 1000) / 10;
      try {
        // Cambiar el volumen local no quita el silencio local del participante;
        // Discord mantiene ambos estados por separado.
        // Un cero elegido manualmente equivale a silencio; no volver a subirlo.
        if (getUserVolume(userId) === 0) continue;
        setUserVolume(userId, target);
        const readback = getUserVolume(userId);
        if (!Number.isFinite(readback) || Math.abs(readback - target) > 2) {
          state.error = "volume";
          continue;
        }
        state.appliedVolume = readback;
        state.lastApplyAt = now;
      } catch (_) { state.error = "volume"; }
    }

    for (const [userId, state] of states) {
      if (seen.has(userId)) continue;
      restore(userId, state);
      states.delete(userId);
      activityLevels.delete(userId);
      statsLevels.delete(userId);
    }
    audio.prune(connections, seen);
  }

  function publish() {
    try {
      window.EquibopVoiceNormalizer?.publish({
        ready: Boolean(stores),
        active: Boolean(voiceChannelId()),
        enabled: runtimeConfig.enabled,
        target_db: runtimeConfig.targetDb,
        participants: [...states].map(([userId, state]) => {
          let actualVolume = state.appliedVolume;
          try {
            const readback = getUserVolume(userId);
            if (Number.isFinite(readback)) actualVolume = readback;
          } catch (_) {}
          return {
            speaking: state.speaking,
            raw_activity: state.rawActivity,
            voice_db: state.voiceDb,
            measured_db: state.measuredDb,
            volume: actualVolume,
            samples: state.samples.length
          };
        })
      });
    } catch (_) {}
  }

  function start() {
    stores = locateStores();
    if (!stores) return false;
    ensureVoiceActivity();
    createControl();
    controlTimer = window.setInterval(tick, CONFIG.intervalMs);
    publishTimer = window.setInterval(publish, 500);
    tick();
    publish();
    return true;
  }

  let attempts = 0;
  bootTimer = window.setInterval(() => {
    if (start() || ++attempts >= 120) {
      window.clearInterval(bootTimer);
      bootTimer = null;
    }
  }, 250);

  window.__equibopVoiceNormalizerStop = () => {
    if (bootTimer) window.clearInterval(bootTimer);
    if (controlTimer) window.clearInterval(controlTimer);
    if (publishTimer) window.clearInterval(publishTimer);
    detachVoiceActivity();
    restoreAll();
    if (documentClickHandler) document.removeEventListener("click", documentClickHandler);
    if (resizeHandler) window.removeEventListener("resize", resizeHandler);
    controlHost?.remove();
    controlHost = null;
    controlButton = null;
    controlTarget = null;
    controlStatus = null;
    documentClickHandler = null;
    bootTimer = null;
    controlTimer = null;
    publishTimer = null;
    stores = null;
  };
})();
