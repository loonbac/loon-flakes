import http from "node:http";
import { TikTokLiveConnection, WebcastEvent } from "tiktok-live-connector";

const args = process.argv.slice(2);
const option = (name, fallback = "") => {
  const index = args.indexOf(name);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
};
const uniqueId = option("--unique-id").replace(/^@/, "").trim();
const showJoins = option("--show-joins", "true") !== "false";
const showLikes = option("--show-likes", "true") !== "false";
const port = Number(option("--port", "5124"));

const state = {
  connected: false,
  status: uniqueId ? "Conectando con TikTok…" : "Configura tu usuario de TikTok en Herramientas → Scripts.",
  chat: [],
  activity: { follow: null, gift: null },
};
const clients = new Set();
let connection = null;
let reconnectTimer = null;
let likes = 0;
let lastLikeAlert = 0;

function clean(value, limit = 240) {
  return typeof value === "string" ? value.replace(/[\u0000-\u001f]/g, " ").slice(0, limit) : "";
}

function user(data) {
  return {
    name: clean(data?.user?.nickname || data?.user?.uniqueId || "Alguien", 80),
    avatar: clean(data?.user?.profilePictureUrl || data?.user?.profilePictureUrls?.[0] || "", 512),
  };
}

function broadcast(event) {
  const payload = `event: alert\ndata: ${JSON.stringify(event)}\n\n`;
  for (const client of clients) client.write(payload);
}

function addChat(data) {
  const sender = user(data);
  const message = clean(data?.comment, 280);
  if (!message) return;
  state.chat.push({ ...sender, message, at: Date.now() });
  state.chat = state.chat.slice(-10);
}

function alert(kind, data, message, detail = "") {
  const sender = user(data);
  broadcast({ kind, name: sender.name, avatar: sender.avatar, message: clean(message, 180), detail: clean(detail, 180), at: Date.now() });
}

function remember(kind, data, text) {
  const sender = user(data);
  state.activity[kind] = { name: sender.name, text: clean(text, 120), at: Date.now() };
}

function scheduleReconnect() {
  if (reconnectTimer || !uniqueId) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, 10000);
}

async function connect() {
  if (!uniqueId) return;
  try {
    connection = new TikTokLiveConnection(uniqueId, { enableExtendedGiftInfo: true, processInitialData: false });
    connection.on(WebcastEvent.CHAT, addChat);
    connection.on(WebcastEvent.GIFT, data => {
      // TikTok emits every update of a streak. Only its final update is an alert.
      if (data?.repeatEnd === false) return;
      const gift = clean(data?.extendedGiftInfo?.name || data?.giftName || `regalo #${data?.giftId || ""}`, 80);
      const count = Math.max(1, Number(data?.repeatCount || 1));
      alert("gift", data, `envió ${gift}`, count > 1 ? `×${count}` : "");
      remember("gift", data, `${gift} ×${count}`);
    });
    connection.on(WebcastEvent.FOLLOW, data => {
      alert("follow", data, "empezó a seguirte");
      remember("follow", data, "nuevo follow");
    });
    connection.on(WebcastEvent.SHARE, data => alert("share", data, "compartió tu directo"));
    if (showJoins) connection.on(WebcastEvent.MEMBER, data => alert("join", data, "se unió al directo"));
    if (showLikes) connection.on(WebcastEvent.LIKE, data => {
      likes += Math.max(1, Number(data?.likeCount || data?.count || 1));
      const now = Date.now();
      if (now - lastLikeAlert >= 5000) {
        alert("like", data, "mandó likes", `+${likes}`);
        likes = 0;
        lastLikeAlert = now;
      }
    });
    connection.on("disconnected", () => {
      state.connected = false;
      state.status = "TikTok se desconectó; reintentando…";
      scheduleReconnect();
    });
    connection.on("error", () => {
      state.connected = false;
      state.status = "No se pudo conectar a TikTok; reintentando…";
    });
    await connection.connect();
    state.connected = true;
    state.status = `Conectado a @${uniqueId}`;
  } catch (_) {
    state.connected = false;
    state.status = "El directo no está disponible; reintentando…";
    scheduleReconnect();
  }
}

const page = (body, script = "") => `<!doctype html><html lang="es"><head><meta charset="utf-8"><style>
*{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent;color:#fff;font-family:system-ui,sans-serif}
${body.style || ""}</style></head><body>${body.html}<script>${script}</script></body></html>`;

const chatPage = page({
  style: `:root{--loon-texto:#f1e2d5;--loon-crema:#dac7b9;--loon-lavanda:#bcb0d5;--loon-azul:#7ca2e0;--loon-secundario:#b0a0bf;--loon-borde:#695d78;--loon-fondo:rgba(27,26,34,.92);--loon-mensaje:30px;--loon-nombre:24px;--loon-entrada:10px;--loon-sans:"Roboto","Segoe UI",Arial,sans-serif;--loon-mono:"JetBrains Mono","Cascadia Code","DejaVu Sans Mono","Liberation Mono",Consolas,monospace}html,body{background:transparent!important;margin:0!important;padding:0!important;width:100%;height:100%;overflow:hidden!important}#chatlist,#chatlist *{box-sizing:border-box;text-shadow:none!important}#chatlist{position:absolute;display:block;left:0;bottom:0;width:100%;margin:0;padding:8px;color:var(--loon-texto);font-family:var(--loon-sans);font-size:var(--loon-mensaje);font-weight:500;line-height:1.38}#chatlist .chatMsg{display:block;margin:0 0 10px;padding:10px 14px;width:100%;min-width:0;max-width:100%;background:var(--loon-fondo);border:1px solid rgba(105,93,120,.35);border-left:2px solid var(--loon-borde);border-radius:6px;box-shadow:none;color:var(--loon-texto);font-size:var(--loon-mensaje);line-height:1.38;overflow-wrap:anywhere;animation:loon-entrada .22s ease-out both}#chatlist .chatMsg:last-child{margin-bottom:0}#chatlist .avatar{display:none}#chatlist .name{display:block;margin:0;color:var(--loon-lavanda);font-family:var(--loon-mono);font-size:var(--loon-nombre);font-weight:700;line-height:1.35;overflow-wrap:anywhere}#chatlist .message{display:block;margin-top:5px;color:var(--loon-texto);font-family:var(--loon-sans);font-size:var(--loon-mensaje);font-weight:500;line-height:1.38;white-space:pre-wrap;overflow-wrap:anywhere;word-break:normal}@keyframes loon-entrada{from{opacity:0;transform:translateY(var(--loon-entrada))}to{opacity:1;transform:translateY(0)}}@media (prefers-reduced-motion:reduce){#chatlist .chatMsg{animation:none}}`,
  html: '<main id="chatlist"></main>',
}, `const target=document.querySelector('#chatlist');const demo=new URLSearchParams(location.search).has('demo');const demoChat=[{name:'Luna',avatar:'',message:'¡Qué buena partida! ✨'},{name:'michi_azul',avatar:'',message:'Saludos desde Perú 🐱'},{name:'LeoGamer',avatar:'',message:'¿Cuál es el siguiente juego?'},{name:'sofia.live',avatar:'',message:'Llegué justo a tiempo 😄'}];let last='';function draw(chat){target.replaceChildren(...chat.map(x=>{const row=document.createElement('article');row.className='chatMsg';const img=document.createElement('img');img.className='avatar';img.src=x.avatar;img.referrerPolicy='no-referrer';const n=document.createElement('span');n.className='name';n.textContent=x.name;const m=document.createElement('span');m.className='message';m.textContent=x.message;row.append(img,n,m);return row}))}async function refresh(){if(demo){draw(demoChat);return}try{const s=await fetch('/state',{cache:'no-store'}).then(r=>r.json()),v=JSON.stringify(s.chat);if(v===last)return;last=v;draw(s.chat)}catch(_){}}refresh();setInterval(refresh,800);`);

const alertsPage = page({
  style: ".alerts{position:fixed;inset:0;display:grid;place-items:center;pointer-events:none}.alert{display:grid;grid-template-columns:88px auto;gap:18px;min-width:460px;max-width:760px;padding:22px 30px;border:2px solid #ff4f9a;border-radius:24px;background:linear-gradient(135deg,#241022ee,#0d1025ee);box-shadow:0 18px 70px #000b;animation:pop 5.4s ease both}.avatar{width:82px;height:82px;border-radius:50%;object-fit:cover;background:#36213e}.kind{font-weight:900;letter-spacing:.12em;color:#ffc1df;font-size:13px;text-transform:uppercase}.name{font-size:28px;font-weight:900;margin-top:4px}.text{font-size:19px;margin-top:4px}.detail{color:#ffe26d;font-weight:900;margin-left:7px}@keyframes pop{0%{opacity:0;transform:scale(.78) translateY(35px)}9%,82%{opacity:1;transform:none}100%{opacity:0;transform:scale(1.04)}}",
  html: '<main id="alerts" class="alerts"></main>',
}, `const root=document.querySelector('#alerts'), labels={gift:'REGALO',follow:'NUEVO FOLLOW',share:'COMPARTIÓ',join:'SE UNIÓ',like:'LIKES'};new EventSource('/events').addEventListener('alert',e=>{const x=JSON.parse(e.data),box=document.createElement('section');box.className='alert';const img=document.createElement('img');img.className='avatar';img.src=x.avatar;img.referrerPolicy='no-referrer';const text=document.createElement('div');const kind=document.createElement('div');kind.className='kind';kind.textContent=labels[x.kind]||'TIKTOK';const name=document.createElement('div');name.className='name';name.textContent=x.name;const line=document.createElement('div');line.className='text';line.textContent=x.message;if(x.detail){const d=document.createElement('span');d.className='detail';d.textContent=x.detail;line.append(d)}text.append(kind,name,line);box.append(img,text);root.replaceChildren(box);setTimeout(()=>box.remove(),5500)});`);

const activityPage = kind => page({
  style: `:root{--activity-color:${kind === "follow" ? "#bcb0d5" : "#dac7b9"}}*{box-sizing:border-box}html,body{width:100%;height:100%;margin:0;background:transparent;overflow:hidden;font-family:"JetBrains Mono","Cascadia Code","DejaVu Sans Mono",monospace}.activity{display:flex;align-items:center;width:100%;height:100%;padding:0;background:transparent;color:var(--activity-color)}.value{width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:25px;font-weight:800;line-height:1.15;letter-spacing:-.6px;text-shadow:0 2px 4px rgba(0,0,0,.82)}.empty{opacity:0}`,
  html: '<main class="activity"><span class="value empty"></span></main>',
}, `const kind=${JSON.stringify(kind)},value=document.querySelector('.value');let last='';async function refresh(){try{const a=(await fetch('/state',{cache:'no-store'}).then(r=>r.json())).activity?.[kind]||null,next=a?JSON.stringify(a):'';if(next===last)return;last=next;value.textContent=a?(kind==='follow'?a.name:a.name+' · '+a.text):'';value.classList.toggle('empty',!a)}catch(_){}}refresh();setInterval(refresh,800);`);

http.createServer((request, response) => {
  const path = new URL(request.url, `http://127.0.0.1:${port}`).pathname;
  if (path === "/state") {
    response.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    return response.end(JSON.stringify(state));
  }
  if (path === "/events") {
    response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" });
    response.write("retry: 1500\n\n");
    clients.add(response);
    request.on("close", () => clients.delete(response));
    return;
  }
  if (path === "/chat" || path === "/") return response.end(chatPage);
  if (path === "/alerts") return response.end(alertsPage);
  if (path === "/activity/follow") return response.end(activityPage("follow"));
  if (path === "/activity/gift") return response.end(activityPage("gift"));
  response.writeHead(404).end();
}).listen(port, "127.0.0.1", connect);
