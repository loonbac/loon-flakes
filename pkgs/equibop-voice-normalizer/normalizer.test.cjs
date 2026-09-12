const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const audioSource = fs.readFileSync(path.join(__dirname, 'audio.js'), 'utf8');

function fixture(contextName = 'default') {
  const nodes = [];
  const tracks = [{ stopped: false, stop() { this.stopped = true; } }];
  function node() {
    const value = { connected: [], disconnects: 0,
      connect(other) { this.connected.push(other); }, disconnect() { this.disconnects++; } };
    nodes.push(value);
    return value;
  }
  const context = {
    state: 'running', currentTime: 1,
    createMediaStreamSource: node,
    createAnalyser() { return Object.assign(node(), { getFloatTimeDomainData(data) { data.fill(0.1); } }); },
    createGain() { return Object.assign(node(), { gain: { value: 1, setTargetAtTime(value) { this.value = value; } } }); },
    createWaveShaper: node,
    createMediaStreamDestination() { return Object.assign(node(), { stream: { getTracks: () => tracks } }); }
  };
  const stream = { getAudioTracks: () => [{}] };
  const element = { srcObject: stream, volume: 1, muted: false, sinkId: 'headphones', play: () => Promise.resolve() };
  const output = { stream, audioContext: context, audioElement: element, _volume: 100, _mute: false,
    updateAudioElement() { this.audioElement.volume = this._volume / 100; this.audioElement.muted = this._mute; },
    destroy() { this.destroyed = true; } };
  const connection = { context: contextName, outputs: { user: output }, volume: 200,
    computeLocalVolume() { return this.volume; } };
  const adapter = vm.runInNewContext(`${audioSource}\ncreateNormalizerAudio()`, { Float32Array });
  return { adapter, output, connection, element, stream, nodes, tracks };
}

test('200% amplifies the audio route, while RMS is measured before gain', () => {
  const f = fixture();
  const measurement = f.adapter.measure([f.connection], 'user');
  assert.ok(Math.abs(measurement.db + 20) < 0.001);
  assert.equal(measurement.gain, 2);
  assert.equal(f.element.volume, 1);
  assert.notEqual(f.element.srcObject, f.stream);
  assert.equal(f.element.sinkId, 'headphones');
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
    assert.equal(f.output.updateAudioElement, original);
    assert.equal(f.tracks[0].stopped, true);
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
