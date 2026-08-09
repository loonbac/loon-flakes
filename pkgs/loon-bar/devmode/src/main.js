// LoonBar DevMode Studio — Interactive Logic, Modular System Panel & Real System Mirroring

document.addEventListener('DOMContentLoaded', () => {
  // --- DOM Elements ---
  const accentPicker = document.getElementById('accentPicker');
  const presetDots = document.querySelectorAll('.preset-dot');
  const btnSyncTheme = document.getElementById('btnSyncTheme');
  
  // Tabs
  const tabBtns = document.querySelectorAll('.tab-btn');
  const tabContents = document.querySelectorAll('.tab-content');

  // Sliders
  const barHeight = document.getElementById('barHeight');
  const barOpacity = document.getElementById('barOpacity');
  const underbarHeight = document.getElementById('underbarHeight');
  const itemMargin = document.getElementById('itemMargin');
  const fontSize = document.getElementById('fontSize');

  const valBarHeight = document.getElementById('valBarHeight');
  const valBarOpacity = document.getElementById('valBarOpacity');
  const valUnderbarHeight = document.getElementById('valUnderbarHeight');
  const valItemMargin = document.getElementById('valItemMargin');
  const valFontSize = document.getElementById('valFontSize');

  // Background
  const bgOpts = document.querySelectorAll('.bg-opt');
  const wallpaper = document.getElementById('wallpaper');

  // UI Interactive & System Panel
  const togglePanelBtn = document.getElementById('togglePanel');
  const sysPanel = document.getElementById('sys-panel');
  const trayBtn = document.getElementById('trayBtn');
  const btnRefreshNiri = document.getElementById('btnRefreshNiri');
  const taskbarGroup = document.getElementById('taskbar-group');

  // Modular System Panel Elements
  const wifiSwitch = document.getElementById('wifiSwitch');
  const wifiList = document.getElementById('wifiList');
  const wifiPasswordBox = document.getElementById('wifiPasswordBox');
  const wifiPasswordEntry = document.getElementById('wifiPasswordEntry');
  const btnConnectWifi = document.getElementById('btnConnectWifi');
  const sysVolIcon = document.getElementById('sysVolIcon');
  const sysVolSlider = document.getElementById('sysVolSlider');
  const sysBattIcon = document.getElementById('sysBattIcon');
  const sysBattLabel = document.getElementById('sysBattLabel');

  // Code Editor
  const cssTextarea = document.getElementById('cssTextarea');
  const btnApplyCss = document.getElementById('btnApplyCss');

  // Clock
  const clockText = document.getElementById('clockText');
  const toast = document.getElementById('toast');
  const toastMsg = document.getElementById('toastMsg');

  // --- Initial State ---
  let state = {
    accent: '#0078d7',
    barHeight: 48,
    barOpacity: 0.94,
    underbarHeight: 3,
    itemMargin: 2,
    fontSize: 12
  };

  let selectedWifiNet = null;

  // Ícono Nerd Font por app_id (Exactamente igual que grouping.rs)
  function getAppIconGlyph(appId) {
    const s = (appId || '').toLowerCase();
    if (s.includes('ghostty') || s.includes('terminal')) return '';
    if (s.includes('zen') || s.includes('firefox') || s.includes('browser') || s.includes('chromium')) return '󰈹';
    if (s.includes('code') || s.includes('antigravity')) return '󰨞';
    if (s.includes('equibop') || s.includes('discord')) return '󰙯';
    if (s.includes('vlc')) return '󰕼';
    if (s.includes('files') || s.includes('nautilus') || s.includes('thunar')) return '󰉋';
    return '󰣆';
  }

  // Nombre de app formateado (Exactamente igual que grouping.rs)
  function formatAppName(title, appId) {
    const name = appId || title || 'App';
    const s = name.toLowerCase();
    if (s.includes('ghostty')) return 'Ghostty';
    if (s.includes('zen')) return 'Zen Browser';
    if (s.includes('firefox')) return 'Firefox';
    if (s.includes('chromium')) return 'Chromium';
    if (s.includes('code') || s.includes('antigravity')) return 'VS Code';
    if (s.includes('equibop')) return 'Equibop';
    const t = title || name;
    return t.length > 20 ? `${t.substring(0, 17)}...` : t;
  }

  // Helper para mezcla de colores de acento (Hover)
  function getAccentHover(hex) {
    if (!hex.startsWith('#') || hex.length !== 7) return '#3a97e2';
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    const mix = c => Math.floor((c + 255) / 2);
    return `#${mix(r).toString(16).padStart(2, '0')}${mix(g).toString(16).padStart(2, '0')}${mix(b).toString(16).padStart(2, '0')}`;
  }

  // Envío en tiempo real a la API (Debounced 50ms)
  let liveTimer = null;
  function postLiveStyleDebounced() {
    clearTimeout(liveTimer);
    liveTimer = setTimeout(() => {
      fetch('/api/live-style', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          accent: state.accent,
          css: cssTextarea.value
        })
      }).catch(err => console.log('Live style update error:', err));
    }, 50);
  }

  function updateThemeVars() {
    const root = document.documentElement;
    const accentHover = getAccentHover(state.accent);
    const accentAlpha = `${state.accent}40`;

    root.style.setProperty('--accent', state.accent);
    root.style.setProperty('--accent-hover', accentHover);
    root.style.setProperty('--accent-alpha', accentAlpha);
    root.style.setProperty('--bar-height', `${state.barHeight}px`);
    root.style.setProperty('--bar-opacity', state.barOpacity);
    root.style.setProperty('--underbar-height', `${state.underbarHeight}px`);
    root.style.setProperty('--item-margin', `${state.itemMargin}px`);
    root.style.setProperty('--bar-font-size', `${state.fontSize}px`);

    generateGtkCssCode();
    postLiveStyleDebounced();
  }

  function generateGtkCssCode() {
    const code = `@define-color accent ${state.accent};
@define-color accent-hover ${getAccentHover(state.accent)};
@define-color accent-alpha ${state.accent}40;

window {
    background-color: rgba(16, 16, 16, ${state.barOpacity});
    color: #ffffff;
    font-family: "Segoe UI", "FiraCode Nerd Font", "Symbols Nerd Font", sans-serif;
}

#start-btn {
    color: #ffffff;
    font-size: 20px;
}

#taskbar-group {
    margin: 0;
    padding: 0;
}

#ws-sep {
    font-size: 18px;
    font-weight: bold;
    color: #ffffff;
    padding: 0 8px;
}

.taskbar-item {
    padding: 0 14px;
    margin: 0 ${state.itemMargin}px;
    background-color: rgba(255, 255, 255, 0.04);
    color: rgba(255, 255, 255, 0.85);
    font-size: ${state.fontSize}px;
    border-bottom: ${state.underbarHeight}px solid rgba(255, 255, 255, 0.35);
    min-height: ${state.barHeight - 8}px;
}
.taskbar-item:hover {
    background-color: rgba(255, 255, 255, 0.10);
    color: #ffffff;
    border-bottom: ${state.underbarHeight}px solid rgba(255, 255, 255, 0.6);
}
.taskbar-item.active {
    background-color: rgba(255, 255, 255, 0.14);
    color: #ffffff;
    border-bottom: ${state.underbarHeight}px solid @accent;
}
.taskbar-item.active:hover {
    background-color: rgba(255, 255, 255, 0.20);
    border-bottom: ${state.underbarHeight}px solid @accent-hover;
}

#tray-box {
    margin-right: 6px;
}
.tray-icon {
    font-size: 14px;
    padding: 6px 8px;
    color: rgba(255, 255, 255, 0.9);
    border-radius: 2px;
}

#clock-label {
    font-size: ${state.fontSize}px;
    font-weight: 600;
    padding: 3px 14px;
}`;
    cssTextarea.value = code;
  }

  // --- Fetch Niri Live Window Snapshot ---
  async function fetchNiriSnapshot() {
    try {
      const res = await fetch('/api/niri-snapshot');
      const data = await res.json();
      if (data.windows && data.windows.length > 0) {
        renderRealNiriTaskbar(data.windows, data.workspaces || []);
        return;
      }
    } catch (e) {
      console.log('Niri snapshot fallback:', e);
    }
    renderMockTaskbar();
  }

  function renderRealNiriTaskbar(windows, workspaces) {
    const wsMap = {};
    (workspaces || []).forEach(w => { wsMap[w.id] = w.idx; });

    const groupsMap = new Map();
    windows.forEach(win => {
      const appId = win.app_id || 'unknown';
      const wsIdx = win.workspace_id ? (wsMap[win.workspace_id] || 0) : 999;
      const key = `${wsIdx}:${appId}`;

      if (groupsMap.has(key)) {
        groupsMap.get(key).windows.push(win);
      } else {
        groupsMap.set(key, {
          appId,
          wsIdx,
          displayName: formatAppName(win.title, appId),
          icon: getAppIconGlyph(appId),
          windows: [win]
        });
      }
    });

    const groups = Array.from(groupsMap.values()).sort((a, b) => a.wsIdx - b.wsIdx);

    taskbarGroup.innerHTML = '';
    let lastWsIdx = null;

    groups.forEach(g => {
      if (lastWsIdx !== null && lastWsIdx !== g.wsIdx) {
        const sep = document.createElement('span');
        sep.className = 'ws-sep';
        sep.textContent = '│';
        taskbarGroup.appendChild(sep);
      }
      lastWsIdx = g.wsIdx;

      const isFocused = g.windows.some(w => w.is_focused);
      const count = g.windows.length;
      let label = `${g.icon} ${g.displayName}`;
      if (count > 1) label += `  ×${count}`;

      const btn = document.createElement('button');
      btn.className = `taskbar-item ${isFocused ? 'active' : ''}`;
      btn.textContent = label;
      taskbarGroup.appendChild(btn);
    });
  }

  function renderMockTaskbar() {
    taskbarGroup.innerHTML = `
      <button class="taskbar-item active"> Ghostty</button>
      <button class="taskbar-item">󰨞 VS Code</button>
      <span class="ws-sep">│</span>
      <button class="taskbar-item">󰈹 Firefox</button>
      <button class="taskbar-item">󰙯 Equibop</button>
    `;
  }

  // --- Fetch System Status (Modular Wi-Fi / Volume / Battery Mirroring) ---
  async function fetchSystemStatus() {
    try {
      const res = await fetch('/api/system-status');
      const data = await res.json();
      renderModularSystemPanel(data);
    } catch (e) {
      console.log('System status fallback:', e);
      renderMockSystemPanel();
    }
  }

  function renderModularSystemPanel(data) {
    if (!data) return;

    // WiFi Module
    const wifi = data.wifi || { enabled: true, nets: [] };
    wifiSwitch.checked = wifi.enabled;
    wifiList.innerHTML = '';

    if (!wifi.enabled) {
      wifiList.innerHTML = `<div class="wifi-net-detail">Wi-Fi apagado</div>`;
    } else if (!wifi.nets || wifi.nets.length === 0) {
      wifiList.innerHTML = `<div class="wifi-net-detail">Sin redes disponibles</div>`;
    } else {
      wifi.nets.forEach(net => {
        const row = document.createElement('div');
        row.className = `wifi-net ${net.connected ? 'connected' : ''}`;
        const lockIcon = net.security !== 'Abierta' ? '' : '󰤨';

        row.innerHTML = `
          <div class="wifi-net-text">
            <div class="wifi-net-name">${net.ssid}</div>
            <div class="wifi-net-detail">${net.signal}% · ${net.security}</div>
          </div>
          <span class="wifi-net-detail">${lockIcon}</span>
        `;

        row.addEventListener('click', () => {
          selectedWifiNet = net;
          if (net.security !== 'Abierta') {
            wifiPasswordBox.classList.remove('hidden');
            wifiPasswordEntry.focus();
          } else {
            wifiPasswordBox.classList.add('hidden');
            showToast(`Conectando a ${net.ssid}...`);
          }
        });

        wifiList.appendChild(row);
      });
    }

    // Volume Module
    const vol = data.volume || { pct: 75, muted: false };
    sysVolSlider.value = vol.pct;
    sysVolIcon.textContent = vol.muted ? '󰝟' : (vol.pct < 50 ? '󰖀' : '󰕾');

    // Battery Module
    const batt = data.battery || { pct: 85, charging: false };
    const battIcon = batt.charging ? '' : (batt.pct >= 80 ? '' : (batt.pct >= 50 ? '' : ''));
    sysBattIcon.textContent = battIcon;
    sysBattLabel.textContent = batt.charging ? `${batt.pct}% (Cargando)` : `${batt.pct}%`;
  }

  function renderMockSystemPanel() {
    renderModularSystemPanel({
      wifi: {
        enabled: true,
        nets: [
          { ssid: 'Fibra_Casa_5G', signal: 95, security: 'WPA2', connected: true },
          { ssid: 'Loonbac_Mobile', signal: 70, security: 'WPA2', connected: false },
          { ssid: 'Plaza_Publica_Free', signal: 45, security: 'Abierta', connected: false }
        ]
      },
      volume: { pct: 75, muted: false },
      battery: { pct: 85, charging: false }
    });
  }

  // --- Event Listeners ---

  // Accent Presets
  presetDots.forEach(dot => {
    dot.addEventListener('click', () => {
      presetDots.forEach(d => d.classList.remove('active'));
      dot.classList.add('active');
      state.accent = dot.dataset.color;
      accentPicker.value = state.accent;
      updateThemeVars();
    });
  });

  accentPicker.addEventListener('input', (e) => {
    state.accent = e.target.value;
    presetDots.forEach(d => d.classList.remove('active'));
    updateThemeVars();
  });

  // Tabs
  tabBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      tabBtns.forEach(b => b.classList.remove('active'));
      tabContents.forEach(c => c.classList.remove('active'));

      btn.classList.add('active');
      const tabId = `tab-${btn.dataset.tab}`;
      document.getElementById(tabId)?.classList.add('active');
    });
  });

  // Sliders
  barHeight.addEventListener('input', (e) => {
    state.barHeight = parseInt(e.target.value);
    valBarHeight.textContent = `${state.barHeight}px`;
    updateThemeVars();
  });

  barOpacity.addEventListener('input', (e) => {
    const val = parseInt(e.target.value);
    state.barOpacity = (val / 100).toFixed(2);
    valBarOpacity.textContent = `${val}%`;
    updateThemeVars();
  });

  underbarHeight.addEventListener('input', (e) => {
    state.underbarHeight = parseInt(e.target.value);
    valUnderbarHeight.textContent = `${state.underbarHeight}px`;
    updateThemeVars();
  });

  itemMargin.addEventListener('input', (e) => {
    state.itemMargin = parseInt(e.target.value);
    valItemMargin.textContent = `${state.itemMargin}px`;
    updateThemeVars();
  });

  fontSize.addEventListener('input', (e) => {
    state.fontSize = parseInt(e.target.value);
    valFontSize.textContent = `${state.fontSize}px`;
    updateThemeVars();
  });

  // Background
  bgOpts.forEach(opt => {
    opt.addEventListener('click', () => {
      bgOpts.forEach(b => b.classList.remove('active'));
      opt.classList.add('active');
      wallpaper.className = `wallpaper ${opt.dataset.bg}`;
    });
  });

  // Panel Toggle
  const togglePanel = () => {
    sysPanel.classList.toggle('hidden');
    if (!sysPanel.classList.contains('hidden')) {
      fetchSystemStatus();
    }
  };
  togglePanelBtn.addEventListener('click', togglePanel);
  trayBtn.addEventListener('click', togglePanel);

  // Modular System Panel Actions
  btnConnectWifi?.addEventListener('click', () => {
    if (selectedWifiNet) {
      showToast(`Conectando a ${selectedWifiNet.ssid}...`);
      wifiPasswordBox.classList.add('hidden');
      wifiPasswordEntry.value = '';
    }
  });

  // Refresh Niri snapshot button
  btnRefreshNiri?.addEventListener('click', () => {
    fetchNiriSnapshot();
    fetchSystemStatus();
    showToast('Ventanas y estado del sistema actualizados');
  });

  // Taskbar Item click
  taskbarGroup.addEventListener('click', (e) => {
    const item = e.target.closest('.taskbar-item');
    if (item) {
      document.querySelectorAll('.taskbar-item').forEach(i => i.classList.remove('active'));
      item.classList.add('active');
    }
  });

  // Apply CSS from Textarea
  btnApplyCss.addEventListener('click', () => {
    const code = cssTextarea.value;
    const accentMatch = code.match(/@define-color accent ([^;]+);/);
    if (accentMatch && accentMatch[1]) {
      state.accent = accentMatch[1].trim();
      accentPicker.value = state.accent;
    }
    updateThemeVars();
    postLiveStyleDebounced();
    showToast('CSS aplicado en caliente a la barra nativa');
  });

  // Sync to theme.rs API
  btnSyncTheme.addEventListener('click', async () => {
    try {
      const response = await fetch('/api/sync-theme', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          accent: state.accent,
          barHeight: state.barHeight,
          barOpacity: state.barOpacity,
          underbarHeight: state.underbarHeight,
          itemMargin: state.itemMargin,
          fontSize: state.fontSize,
          css: cssTextarea.value
        })
      });

      if (response.ok) {
        showToast('✓ Sincronizado permanentemente en pkgs/loon-bar/src/theme.rs');
      } else {
        showToast('✓ Estilos actualizados en vivo');
      }
    } catch {
      showToast('✓ Configuración enviada');
    }
  });

  function showToast(msg) {
    toastMsg.textContent = msg;
    toast.classList.remove('hidden');
    setTimeout(() => toast.classList.add('hidden'), 3000);
  }

  // Live Clock Ticker
  function updateClock() {
    const now = new Date();
    let hours = now.getHours();
    const minutes = String(now.getMinutes()).padStart(2, '0');
    const ampm = hours >= 12 ? 'PM' : 'AM';
    hours = hours % 12 || 12;
    const timeStr = `${String(hours).padStart(2, '0')}:${minutes} ${ampm}`;
    const dateStr = `${String(now.getDate()).padStart(2, '0')}/${String(now.getMonth() + 1).padStart(2, '0')}/${now.getFullYear()}`;

    clockText.innerHTML = `${timeStr}<br>${dateStr}`;
  }
  setInterval(updateClock, 1000);
  updateClock();

  // Initial render & sync
  updateThemeVars();
  fetchNiriSnapshot();
  fetchSystemStatus();
  setInterval(fetchNiriSnapshot, 2000);
});
