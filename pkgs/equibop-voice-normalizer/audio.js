// Adaptador del receptor WebRTC: conserva el elemento de audio y su dispositivo
// de salida, pero procesa la señal antes de reproducirla (HTMLAudio limita a 1).
function createNormalizerAudio() {
  const routes = new Map();
  const modules = new WeakMap();
  const processorName = `equibop-realtime-normalizer-${Date.now()}`;
  let targetDb = -24;

  function loadProcessor(context) {
    if (!modules.has(context)) {
      const code = `(${installRealtimeNormalizer.toString().replace("'equibop-realtime-normalizer'", JSON.stringify(processorName))})();`;
      const url = URL.createObjectURL(new Blob([code], { type: 'text/javascript' }));
      modules.set(context, context.audioWorklet.addModule(url).finally(() => URL.revokeObjectURL(url)));
    }
    return modules.get(context);
  }

  function ensurePlayback(route, forcePlay = false) {
    if (route.context.state === "suspended" && !route.resumePending) {
      route.resumePending = Promise.resolve(route.context.resume?.())
        .then(() => route.element.play?.())
        .catch(() => {})
        .finally(() => { route.resumePending = null; });
      return;
    }
    if (route.context.state === "running" && (forcePlay || route.element.paused) && !route.playPending) {
      route.playPending = Promise.resolve(route.element.play?.())
        .catch(() => {})
        .finally(() => { route.playPending = null; });
    }
  }

  function disableRealtime(route, output) {
    const processor = route.processor;
    if (!processor) return;
    try { processor.port.postMessage({ stop: true }); } catch (_) {}
    try { processor.port.close(); } catch (_) {}
    try { processor.disconnect(); } catch (_) {}
    try { route.analyser.disconnect(); } catch (_) {}
    route.analyser.connect(route.gain);
    route.processor = null;
    route.failed = true;
    route.retryRealtimeAt = Date.now() + 3000;
    route.update.call(output);
    ensurePlayback(route, true);
  }

  async function enableRealtime(route, connection, userId, output) {
    if (route.processor || route.startingRealtime || !route.context.audioWorklet
        || typeof connection.getLocalVolume !== 'function') return;
    route.startingRealtime = true;
    try {
      await loadProcessor(route.context);
      if (routes.get(output) !== route) return;
      const processor = new AudioWorkletNode(route.context, processorName, {
        processorOptions: { targetDb, initialGain: Math.max(0.05, Math.min(8, connection.getLocalVolume(userId) / 100)) }
      });
      route.processor = processor;
      route.realtimeGain = Math.max(0.05, Math.min(8, connection.getLocalVolume(userId) / 100));
      route.lastProcessAt = Date.now();
      processor.port.onmessage = ({ data }) => {
        route.lastProcessAt = Date.now();
        if (Number.isFinite(data.gain)) route.realtimeGain = data.gain;
      };
      processor.onprocessorerror = () => disableRealtime(route, output);
      route.analyser.disconnect();
      route.analyser.connect(processor);
      processor.connect(route.gain);
      route.failed = false;
      route.update.call(output);
      ensurePlayback(route);
    } catch (_) {
      route.failed = true;
      route.retryRealtimeAt = Date.now() + 3000;
    } finally {
      route.startingRealtime = false;
    }
  }
  // Limitador suave con ganancia unitaria para voz normal. El compresor nativo
  // añade makeup gain automático y alteraría el objetivo incluso bajo el umbral.
  const curve = Float32Array.from({ length: 4097 }, (_, index) => {
    const value = index / 2048 - 1;
    const amplitude = Math.abs(value);
    return amplitude <= 0.7 ? value : Math.sign(value) * (0.7 + 0.19 * Math.tanh((amplitude - 0.7) / 0.19));
  });

  function detach(output) {
    const route = routes.get(output);
    if (!route) return;
    routes.delete(output);
    if (route.processor) {
      route.processor.port.postMessage({ stop: true });
      route.processor.port.close();
      route.processor.disconnect();
    }
    if (output.updateAudioElement === route.update) {
      output.updateAudioElement = route.originalUpdate;
    }
    if (output.destroy === route.destroy) output.destroy = route.originalDestroy;
    if (route.element.srcObject === route.destination.stream) {
      route.element.srcObject = output.stream;
    }
    if (route.keepAlive) {
      try { route.keepAlive.stop(); } catch (_) {}
      route.keepAlive.disconnect();
    }
    for (const node of [route.source, route.analyser, route.gain, route.limiter]) node.disconnect();
    for (const track of route.destination.stream.getTracks()) track.stop();
    route.originalUpdate.call(output);
  }

  function attach(connection, userId) {
    const output = connection.outputs?.[userId];
    const inputTrack = output?.stream?.getAudioTracks?.()[0];
    if (!output?.audioElement || !inputTrack
        || !output.audioContext || typeof connection.computeLocalVolume !== "function"
        || typeof output.updateAudioElement !== "function" || typeof output.destroy !== "function") return null;
    const previous = routes.get(output);
    // Discord conserva el objeto output/audioElement, pero reemplaza el
    // MediaStream o su pista al renegociar SSRCs y participantes. Reutilizar la
    // ruta sólo por identidad del elemento deja el worklet leyendo una pista
    // vieja: la voz reaparece brevemente con una notificación/desconexión y
    // vuelve a quedar muda. La identidad completa evita esa ruta zombi.
    if (previous?.element === output.audioElement
        && previous.inputStream === output.stream
        && previous.inputTrack === inputTrack
        && inputTrack.readyState !== "ended") return previous;
    if (previous) detach(output);
    const context = output.audioContext;
    const source = context.createMediaStreamSource(output.stream);
    const analyser = context.createAnalyser();
    analyser.fftSize = 2048;
    const gain = context.createGain();
    const limiter = context.createWaveShaper();
    limiter.curve = curve;
    limiter.oversample = "2x";
    const destination = context.createMediaStreamDestination();
    // Chromium puede considerar inactivo un MediaStreamDestination silencioso
    // y encorchar su salida Pulse/PipeWire. En ese estado la voz sólo reaparece
    // brevemente cuando una notificación despierta AudioService. Una componente
    // DC muy por debajo del piso audible mantiene el grafo demandado sin añadir
    // sonido perceptible ni entrar al analizador/normalizador.
    const keepAlive = typeof context.createConstantSource === "function"
      ? context.createConstantSource()
      : null;
    if (keepAlive) {
      keepAlive.offset.value = 0.0000001;
      keepAlive.connect(destination);
      keepAlive.start();
    }
    source.connect(analyser);
    analyser.connect(gain);
    gain.connect(limiter);
    limiter.connect(destination);
    const route = {
      source, analyser, gain, limiter, destination, keepAlive, context,
      inputStream: output.stream, inputTrack,
      element: output.audioElement, samples: new Float32Array(analyser.fftSize),
      originalUpdate: output.updateAudioElement, originalDestroy: output.destroy
    };
    route.update = function (...args) {
      const result = route.originalUpdate.apply(this, args);
      // computeLocalVolume incluye volumen maestro y prioridad de hablantes.
      const volume = connection.computeLocalVolume(userId);
      const local = route.processor ? connection.getLocalVolume(userId) : 100;
      // El worklet aplica la normalización. Aquí sólo quedan volumen maestro,
      // prioridad y silencio; el porcentaje de Discord refleja la ganancia sin
      // aplicarla una segunda vez.
      const amplitude = this._mute || !Number.isFinite(volume) || !(local > 0) ? 0 : Math.max(0, volume / local);
      gain.gain.setTargetAtTime(amplitude, context.currentTime, 0.035);
      route.element.volume = 1;
      return result;
    };
    route.destroy = function (...args) {
      detach(output);
      return route.originalDestroy.apply(this, args);
    };
    routes.set(output, route);
    output.updateAudioElement = route.update;
    output.destroy = route.destroy;
    route.element.srcObject = destination.stream;
    route.update.call(output);
    ensurePlayback(route, true);
    void enableRealtime(route, connection, userId, output);
    return route;
  }

  return {
    measure(connections, userId, nextTargetDb = -24) {
      if (targetDb !== nextTargetDb) {
        targetDb = nextTargetDb;
        for (const route of routes.values()) route.processor?.port.postMessage({ targetDb });
      }
      // Nunca interceptar audio de streams, soundboard ni nuestra propia entrada.
      const connection = connections.find(item => item?.context === "default" && item.outputs?.[userId]);
      if (!connection) return null;
      const output = connection.outputs[userId];
      const route = attach(connection, userId);
      if (!route) return null;
      ensurePlayback(route);
      if (route.processor && Date.now() - route.lastProcessAt > 1500) {
        disableRealtime(route, output);
      }
      if (!route.processor && !route.startingRealtime
          && Date.now() >= (route.retryRealtimeAt || 0)) {
        void enableRealtime(route, connection, userId, output);
      }
      if (route.context.state !== "running") return null;
      route.analyser.getFloatTimeDomainData(route.samples);
      const power = route.samples.reduce((sum, value) => sum + value * value, 0) / route.samples.length;
      return {
        db: power > 0 ? Math.max(-100, 10 * Math.log10(power)) : -100,
        gain: route.processor ? route.realtimeGain : route.gain.gain.value,
        realtime: Boolean(route.processor), failed: Boolean(route.failed)
      };
    },
    prune(connections, userIds) {
      const outputs = new Set(connections.filter(item => item?.context === "default")
        .flatMap(connection => [...userIds].map(id => connection.outputs?.[id])).filter(Boolean));
      for (const output of routes.keys()) if (!outputs.has(output)) detach(output);
    },
    stop() { for (const output of routes.keys()) detach(output); }
  };
}
