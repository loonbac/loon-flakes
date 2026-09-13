const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const base = __dirname + '/';
const script = `(() => { ${['worklet.js','audio.js','renderer.js'].map(file=>fs.readFileSync(base+file,'utf8')).join('\n')} })();`;
(async () => {
  const browser = await chromium.launch({ executablePath: '/run/current-system/sw/bin/chromium', args: ['--autoplay-policy=no-user-gesture-required'] });
  try {
    const page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route('http://localhost/', route => route.fulfill({ contentType:'text/html', body:'<html><body>Chat de prueba</body></html>' }));
    await page.goto('http://localhost/');
    await page.evaluate(async () => {
      const context = new AudioContext();
      await context.resume();
      const oscillator = context.createOscillator();
      const input = context.createGain();
      input.gain.value = 0.025;
      const destination = context.createMediaStreamDestination();
      oscillator.connect(input).connect(destination);
      oscillator.start();
      // Espía la señal que el adaptador envía al destino real del contexto.
      // La producción no crea este MediaStreamDestination: sólo existe aquí
      // para poder verificar el PCM sin depender del hardware de la prueba.
      const outputTap = context.createMediaStreamDestination();
      const createWaveShaper = context.createWaveShaper.bind(context);
      context.createWaveShaper = () => {
        const node = createWaveShaper();
        const connect = node.connect.bind(node);
        node.connect = (target, ...args) => {
          if (target === context.destination) connect(outputTap);
          return connect(target, ...args);
        };
        return node;
      };
      const element = new Audio();
      element.srcObject = destination.stream;
      await element.play();
      const output = { stream: destination.stream, audioElement:element, audioContext:context, _mute:false, _volume:100,
        updateAudioElement() { element.volume=this._volume/100; element.muted=this._mute; }, destroy() {} };
      const connection = {context:'default', outputs:{other:output}, volume:100, getLocalVolume() { return this.volume; }, computeLocalVolume() { return this.volume; }};
      const engine = { connections:new Set([connection]), on(){}, off(){} };
      window.testFixture = { context, input, output, connection, originalStream:destination.stream, outputStream:outputTap.stream };
      window.EquibopVoiceNormalizer = { publish(value) { window.metrics=value; } };
      window.Vencord = {Webpack:{ Common:{
        UserStore:{getCurrentUser:()=>({id:'self'}),getUser:()=>({})},
        VoiceStateStore:{getVoiceStatesForChannel:()=>({a:{userId:'self'},b:{userId:'other'}}), getAllVoiceStates:()=>({})},
        SelectedChannelStore:{getVoiceChannelId:()=> 'call'},
        MediaEngineStore:{getMediaEngine:()=>engine,getLocalVolume:()=>connection.volume},
        FluxDispatcher:{dispatch(event){ connection.volume=event.volume; output._volume=Math.min(100,event.volume); output.updateAudioElement(); },subscribe(){}},
        ChannelRTCStore:{getParticipants:()=>[],getSpeakingParticipants:()=>[]}
      }}};
    });
    await page.evaluate(script);
    await page.waitForFunction(() => window.metrics?.participants[0]?.volume > 340, null, {timeout:12000});
    const status = await page.locator('#status').textContent();
    assert.match(status, /1 en tiempo real/);
    assert.equal(await page.evaluate(() => testFixture.output.audioElement.srcObject === testFixture.originalStream),true);
    assert.equal(await page.evaluate(() => testFixture.output.audioElement.paused),true);
    // Discord/Chromium puede suspender el AudioContext al quedar inactivo. La
    // ruta debe despertarse sola, sin depender del sonido de una notificación.
    await page.evaluate(() => testFixture.context.suspend());
    await page.waitForFunction(() => testFixture.context.state === 'running', null, {timeout:3000});
    assert.equal(await page.evaluate(() => testFixture.output.audioElement.paused), true);
    // Read actual PCM from the test tap after the gain: compare input/output RMS.
    const pcm = await page.evaluate(async () => {
      const {context,outputStream,originalStream}=testFixture;
      const a=context.createAnalyser(), b=context.createAnalyser();
      const sourceA=context.createMediaStreamSource(originalStream), sourceB=context.createMediaStreamSource(outputStream);
      sourceA.connect(a); sourceB.connect(b);
      await new Promise(resolve=>setTimeout(resolve,350));
      const rms=n=>{const values=new Float32Array(n.fftSize); n.getFloatTimeDomainData(values); return Math.sqrt(values.reduce((s,v)=>s+v*v,0)/values.length);};
      const values={input:rms(a),output:rms(b)};
      sourceA.disconnect(); sourceB.disconnect(); a.disconnect(); b.disconnect();
      return values;
    });
    assert.ok(Math.abs(20*Math.log10(pcm.output)+24)<1,JSON.stringify(pcm));
    await page.evaluate(()=>{testFixture.input.gain.value=0.5;});
    await page.waitForFunction(()=>metrics.participants[0].volume<19,null,{timeout:14000});
    const loud=await page.evaluate(()=>metrics.participants[0]);
    assert.ok(loud.volume>10, JSON.stringify(loud));
    assert.ok(Math.abs(loud.measured_db + 20*Math.log10(loud.volume/100)+24)<1, JSON.stringify(loud));
    const loudPcm = await page.evaluate(async () => {
      const { context, outputStream } = testFixture;
      const source = context.createMediaStreamSource(outputStream);
      const analyser = context.createAnalyser();
      source.connect(analyser);
      await new Promise(resolve=>setTimeout(resolve,350));
      const values = new Float32Array(analyser.fftSize);
      analyser.getFloatTimeDomainData(values);
      source.disconnect(); analyser.disconnect();
      return Math.sqrt(values.reduce((sum,value)=>sum+value*value,0)/values.length);
    });
    assert.ok(Math.abs(20*Math.log10(loudPcm/pcm.output))<1,JSON.stringify({loudPcm,quietPcm:pcm.output}));
    // A scheduled level change must be normalized while the UI thread is blocked.
    const busyPcm = await page.evaluate(() => {
      const { context, outputStream, input } = testFixture;
      const source = context.createMediaStreamSource(outputStream);
      const analyser = context.createAnalyser();
      source.connect(analyser);
      input.gain.setValueAtTime(0.025, context.currentTime+0.15);
      const until = performance.now()+700;
      while (performance.now()<until) {}
      const values = new Float32Array(analyser.fftSize);
      analyser.getFloatTimeDomainData(values);
      source.disconnect(); analyser.disconnect();
      return Math.sqrt(values.reduce((sum,value)=>sum+value*value,0)/values.length);
    });
    assert.ok(Math.abs(20*Math.log10(busyPcm)+24)<1,JSON.stringify({busyPcm}));
    const handle=page.locator('#move');
    const before=await handle.boundingBox();
    await page.mouse.move(before.x+8,before.y+8);
    await page.mouse.down();
    await page.mouse.move(600,180,{steps:8});
    await page.mouse.up();
    const after=await handle.boundingBox();
    assert.ok(after.x>500 && after.y<200,JSON.stringify(after));
    await page.locator('#toggle').click();
    assert.equal(await page.locator('#panel').isVisible(),true);
    // Reload in place and check both the saved position and resource cleanup.
    await page.evaluate(script);
    await page.waitForTimeout(400);
    const reloaded=await handle.boundingBox();
    assert.ok(Math.abs(reloaded.x-after.x)<2 && Math.abs(reloaded.y-after.y)<2);
    assert.equal(await page.locator('#equibop-voice-normalizer-control').count(),1);
    await page.setViewportSize({width:350,height:300});
    await page.waitForFunction(()=>document.getElementById('equibop-voice-normalizer-control').getBoundingClientRect().right<=350);
    const resized=await handle.boundingBox();
    assert.ok(resized.x<350 && resized.y<300);
    await page.locator('#toggle').click();
    await page.locator('#enabled').uncheck();
    assert.equal(await page.evaluate(()=>testFixture.output.audioElement.srcObject===testFixture.originalStream),true);
    assert.equal(await page.evaluate(()=>testFixture.output.audioElement.paused),false);
    assert.equal(await page.evaluate(()=>testFixture.connection.volume),100);
    await page.evaluate(()=>{testFixture.connection.volume=0;testFixture.output._volume=0;testFixture.output.updateAudioElement();});
    await page.locator('#enabled').check();
    await page.waitForTimeout(1500);
    assert.equal(await page.evaluate(()=>testFixture.connection.volume),0,'manual zero is never boosted');
    await page.locator('#enabled').uncheck();
    assert.equal(await page.evaluate(()=>testFixture.connection.volume),0);
    await page.evaluate(()=>window.__equibopVoiceNormalizerStop());
    assert.equal(await page.locator('#equibop-voice-normalizer-control').count(),0);
    assert.deepEqual(errors,[]);
    console.log(JSON.stringify({pcm,amplification:pcm.output/pcm.input,loud,loudPcm,busyPcm,drag:{before,after,reloaded,resized},status,errors},null,2));
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1;});
