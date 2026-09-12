// Se serializa para AudioWorklet; no depende de DOM, IPC ni timers del chat.
function installRealtimeNormalizer() {
  class VoiceNormalizer extends AudioWorkletProcessor {
    constructor(options) {
      super();
      this.target = Math.pow(10, (options.processorOptions?.targetDb ?? -24) / 20);
      this.gain = options.processorOptions?.initialGain ?? 1;
      this.levelDb = null;
      this.silence = 0;
      this.elapsed = 0;
      this.stopped = false;
      this.port.onmessage = ({ data }) => {
        if (data.stop) this.stopped = true;
        if (Number.isFinite(data.targetDb)) this.target = Math.pow(10, Math.max(-36, Math.min(-12, data.targetDb)) / 20);
      };
    }

    process(inputs, outputs) {
      if (this.stopped) return false;
      const input = inputs[0];
      const output = outputs[0];
      if (!input?.length || !output?.length) return true;
      const frames = input[0].length;
      const dt = frames / sampleRate;
      let power = 0;
      for (const channel of input) for (const sample of channel) power += sample * sample;
      power /= frames * input.length;
      let nextGain = this.gain;
      if (power >= Math.pow(10, -55 / 10)) {
        const db = 10 * Math.log10(power);
        if (this.levelDb === null || this.silence > 0.3) this.levelDb = db;
        const envelopeTime = db > this.levelDb ? 0.008 : 0.035;
        this.levelDb += (db - this.levelDb) * (1 - Math.exp(-dt / envelopeTime));
        const desired = Math.max(0.05, Math.min(8, this.target / Math.pow(10, this.levelDb / 20)));
        // Atenúa en milisegundos; amplifica más suavemente para no bombear ruido.
        const gainTime = desired < this.gain ? 0.008 : 0.06;
        nextGain += (desired - nextGain) * (1 - Math.exp(-dt / gainTime));
        this.silence = 0;
      } else {
        this.silence += dt;
      }
      for (let c = 0; c < output.length; c++) {
        const source = input[Math.min(c, input.length - 1)];
        for (let i = 0; i < output[c].length; i++) {
          output[c][i] = source[i] * (this.gain + (nextGain - this.gain) * (i + 1) / frames);
        }
      }
      this.gain = nextGain;
      this.elapsed += dt;
      if (this.elapsed >= 0.05) {
        this.elapsed = 0;
        this.port.postMessage({ gain: this.gain, db: power > 0 ? Math.max(-100, 10 * Math.log10(power)) : -100 });
      }
      return true;
    }
  }
  registerProcessor('equibop-realtime-normalizer', VoiceNormalizer);
}
