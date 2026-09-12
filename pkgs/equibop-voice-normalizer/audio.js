// Adaptador del receptor WebRTC: conserva el elemento de audio y su dispositivo
// de salida, pero procesa la señal antes de reproducirla (HTMLAudio limita a 1).
function createNormalizerAudio() {
  const routes = new Map();
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
    if (output.updateAudioElement === route.update) {
      output.updateAudioElement = route.originalUpdate;
    }
    if (output.destroy === route.destroy) output.destroy = route.originalDestroy;
    if (route.element.srcObject === route.destination.stream) {
      route.element.srcObject = output.stream;
    }
    for (const node of [route.source, route.analyser, route.gain, route.limiter]) node.disconnect();
    for (const track of route.destination.stream.getTracks()) track.stop();
    route.originalUpdate.call(output);
  }

  function attach(connection, userId) {
    const output = connection.outputs?.[userId];
    if (!output?.audioElement || !output.stream?.getAudioTracks().length
        || !output.audioContext || typeof connection.computeLocalVolume !== "function"
        || typeof output.updateAudioElement !== "function" || typeof output.destroy !== "function") return null;
    const previous = routes.get(output);
    if (previous?.element === output.audioElement) return previous;
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
    source.connect(analyser);
    analyser.connect(gain);
    gain.connect(limiter);
    limiter.connect(destination);
    const route = {
      source, analyser, gain, limiter, destination, context,
      element: output.audioElement, samples: new Float32Array(analyser.fftSize),
      originalUpdate: output.updateAudioElement, originalDestroy: output.destroy
    };
    route.update = function (...args) {
      const result = route.originalUpdate.apply(this, args);
      // computeLocalVolume incluye volumen maestro y prioridad de hablantes.
      const volume = connection.computeLocalVolume(userId);
      const amplitude = this._mute || !Number.isFinite(volume) ? 0 : Math.max(0, volume / 100);
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
    route.element.play()?.catch(() => {});
    return route;
  }

  return {
    measure(connections, userId) {
      // Nunca interceptar audio de streams, soundboard ni nuestra propia entrada.
      const connection = connections.find(item => item?.context === "default" && item.outputs?.[userId]);
      if (!connection) return null;
      const route = attach(connection, userId);
      if (!route || route.context.state !== "running") return null;
      route.analyser.getFloatTimeDomainData(route.samples);
      const power = route.samples.reduce((sum, value) => sum + value * value, 0) / route.samples.length;
      return { db: power > 0 ? Math.max(-100, 10 * Math.log10(power)) : -100, gain: route.gain.gain.value };
    },
    prune(connections, userIds) {
      const outputs = new Set(connections.filter(item => item?.context === "default")
        .flatMap(connection => [...userIds].map(id => connection.outputs?.[id])).filter(Boolean));
      for (const output of routes.keys()) if (!outputs.has(output)) detach(output);
    },
    stop() { for (const output of routes.keys()) detach(output); }
  };
}
