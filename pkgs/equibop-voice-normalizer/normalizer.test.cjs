const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const audioSource = fs.readFileSync(path.join(__dirname, 'audio.js'), 'utf8');
const workletSource = fs.readFileSync(path.join(__dirname, 'worklet.js'), 'utf8');

function realtimeFixture() {
  let Processor;
  vm.runInNewContext(`${workletSource}\ninstallRealtimeNormalizer()`, {
    sampleRate: 48000,
    AudioWorkletProcessor: class { constructor() { this.port = { postMessage() {} }; } },
    registerProcessor(name, constructor) { Processor = constructor; }
  });
  const processor = new Processor({ processorOptions: { targetDb: -24, initialGain: 1 } });
  let position = 0;
  return {
    processor,
    run(amplitude, milliseconds) {
      const blocks = Math.ceil(milliseconds * 48 / 128);
      let power = 0;
      for (let b = 0; b < blocks; b++) {
        const input = Float32Array.from({length:128},()=>amplitude*Math.sin(2*Math.PI*1000*position++/48000));
        const output = new Float32Array(128);
        processor.process([[input]],[[output]]);
        power = output.reduce((sum, value)=>sum+value*value,0)/128;
      }
      return power>0 ? 10*Math.log10(power) : -Infinity;
    }
  };
}

test('audio-thread AGC reaches target quickly in both directions without UI ticks', () => {
  const f = realtimeFixture();
  assert.ok(Math.abs(f.run(0.025,250)+24)<1);
  const loudDb = f.run(0.5,80);
  assert.ok(Math.abs(loudDb+24)<1, `loud after 80 ms: ${loudDb}`);
  const quietDb = f.run(0.025,350);
  assert.ok(Math.abs(quietDb+24)<1, `quiet after 350 ms: ${quietDb}`);
});

test('realtime silence holds gain, target changes propagate and stop releases processor', () => {
  const f = realtimeFixture();
  f.run(0.025,500);
  const gain = f.processor.gain;
  assert.equal(f.run(0,1000), -Infinity);
  assert.equal(f.processor.gain,gain);
  f.processor.port.onmessage({data:{targetDb:-18}});
  assert.ok(Math.abs(f.run(0.025,350)+18)<1);
  f.processor.port.onmessage({data:{stop:true}});
  assert.equal(f.processor.process([],[]),false);
});

function fixture(contextName = 'default') {
  const nodes = [];
  function node() {
    const value = { connected: [], disconnects: 0,
      connect(other) { this.connected.push(other); }, disconnect() { this.disconnects++; } };
    nodes.push(value);
    return value;
  }
  const destination = { name: 'audio-context-destination' };
  const context = {
    state: 'running', currentTime: 1, destination, sinkId: '',
    setSinkId(value) { this.sinkId = value; return Promise.resolve(); },
    createMediaStreamSource: node,
    createAnalyser() { return Object.assign(node(), { getFloatTimeDomainData(data) { data.fill(0.1); } }); },
    createGain() { return Object.assign(node(), { gain: { value: 1, setTargetAtTime(value) { this.value = value; } } }); },
    createWaveShaper: node
  };
  const sourceTrack = { readyState: 'live' };
  const stream = { getAudioTracks: () => [sourceTrack] };
  const element = {
    srcObject: stream, volume: 1, muted: false, sinkId: 'headphones', paused: false,
    pause() { this.paused = true; },
    play() { this.paused = false; return Promise.resolve(); }
  };
  const output = { stream, audioContext: context, audioElement: element, _volume: 100, _mute: false,
    updateAudioElement() { this.audioElement.volume = this._volume / 100; this.audioElement.muted = this._mute; },
    destroy() { this.destroyed = true; } };
  const connection = { context: contextName, outputs: { user: output }, volume: 200,
    computeLocalVolume() { return this.volume; } };
  const adapter = vm.runInNewContext(`${audioSource}\ncreateNormalizerAudio()`, { Float32Array });
  return { adapter, output, connection, element, stream, sourceTrack, nodes, destination, context };
}

test('200% amplifies the audio route, while RMS is measured before gain', () => {
  const f = fixture();
  const measurement = f.adapter.measure([f.connection], 'user');
  assert.ok(Math.abs(measurement.db + 20) < 0.001);
  assert.equal(measurement.gain, 2);
  assert.equal(f.element.srcObject, f.output.stream);
  assert.equal(f.element.paused, true);
  assert.equal(f.element.sinkId, 'headphones');
  assert.equal(f.context.sinkId, 'headphones');
  assert.ok(f.nodes.some(node => node.connected.includes(f.destination)), 'processed audio reaches the context output');
  const count = f.nodes.length;
  f.adapter.measure([f.connection], 'user');
  assert.equal(f.nodes.length, count, 'do not duplicate playback routes');
  f.connection.volume = 800;
  f.output.updateAudioElement();
  assert.equal(f.adapter.measure([f.connection], 'user').gain, 8);
  const curve = f.nodes.find(node => node.curve)?.curve;
  assert.equal(curve[2048], 0);
  assert.ok(Math.abs(curve[3072] - 0.5) < 0.001, 'ordinary samples have unity gain');
  assert.ok(curve[4096] < 0.9, 'peaks are limited');
});

test('mute/deafen applies immediately and master volume changes reach the gain', () => {
  const f = fixture();
  f.adapter.measure([f.connection], 'user');
  f.output._mute = true;
  f.output.updateAudioElement();
  assert.equal(f.element.muted, true);
  assert.equal(f.adapter.measure([f.connection], 'user').gain, 0);
  f.output._mute = false;
  f.connection.volume = 50;
  f.output.updateAudioElement();
  assert.equal(f.adapter.measure([f.connection], 'user').gain, 0.5);
});

test('leaving, disabling and output destruction restore playback and release resources', () => {
  for (const mode of ['prune', 'stop', 'destroy']) {
    const f = fixture();
    const original = f.output.updateAudioElement;
    f.adapter.measure([f.connection], 'user');
    if (mode === 'prune') f.adapter.prune([], new Set());
    else if (mode === 'stop') f.adapter.stop();
    else f.output.destroy();
    assert.equal(f.element.srcObject, f.stream);
    assert.equal(f.element.paused, false);
    assert.equal(f.output.updateAudioElement, original);
    assert.equal(f.nodes.filter(n => n.disconnects).length, 4);
    if (mode === 'destroy') assert.equal(f.output.destroyed, true);
    f.adapter.stop();
  }
});

test('screen-share outputs and unknown users are not intercepted', () => {
  const f = fixture('stream');
  assert.equal(f.adapter.measure([f.connection], 'user'), null);
  assert.equal(f.adapter.measure([f.connection], 'other'), null);
  assert.equal(f.nodes.length, 0);
});

test('replaces a stale route when Discord swaps its MediaStream track', () => {
  const f = fixture();
  f.adapter.measure([f.connection], 'user');
  const firstSource = f.nodes[0];
  const replacementTrack = { readyState: 'live' };
  f.output.stream = { getAudioTracks: () => [replacementTrack] };

  f.adapter.measure([f.connection], 'user');

  assert.equal(firstSource.disconnects, 1);
  assert.equal(f.element.srcObject, f.output.stream);
  const nodeCount = f.nodes.length;
  f.adapter.measure([f.connection], 'user');
  assert.equal(f.nodes.length, nodeCount, 'the replacement route remains stable');
});
