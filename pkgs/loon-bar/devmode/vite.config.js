import { defineConfig } from 'vite';
import fs from 'fs';
import path from 'path';
import os from 'os';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

export default defineConfig({
  server: {
    port: 5173,
    host: '0.0.0.0'
  },
  plugins: [
    {
      name: 'gtk-theme-sync',
      configureServer(server) {
        // Snapshot de ventanas y workspaces activos en Niri
        server.middlewares.use('/api/niri-snapshot', async (req, res) => {
          try {
            const [winRes, wsRes] = await Promise.all([
              execAsync('niri msg -j windows 2>/dev/null').catch(() => ({ stdout: '[]' })),
              execAsync('niri msg -j workspaces 2>/dev/null').catch(() => ({ stdout: '[]' }))
            ]);

            const windows = JSON.parse(winRes.stdout.trim() || '[]');
            const workspaces = JSON.parse(wsRes.stdout.trim() || '[]');

            res.statusCode = 200;
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify({ windows, workspaces }));
          } catch (err) {
            res.statusCode = 200;
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify({ windows: [], workspaces: [] }));
          }
        });

        // Estado del sistema real (WiFi, Volumen, Batería)
        server.middlewares.use('/api/system-status', async (req, res) => {
          try {
            const [wifiRes, volRes, battRes] = await Promise.all([
              execAsync('nmcli -t -e yes -f SSID,SIGNAL,SECURITY,ACTIVE dev wifi list 2>/dev/null').catch(() => ({ stdout: '' })),
              execAsync('wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null').catch(() => ({ stdout: 'Volume: 0.75' })),
              execAsync('cat /sys/class/power_supply/BAT0/capacity /sys/class/power_supply/BAT0/status 2>/dev/null').catch(() => ({ stdout: '85\nDischarging' }))
            ]);

            const nets = [];
            (wifiRes.stdout || '').split('\n').forEach(line => {
              if (!line.trim()) return;
              const parts = line.split(':');
              const ssid = (parts[0] || '').replace(/\\:/g, ':');
              const signal = parseInt(parts[1] || '0', 10);
              const security = (parts[2] || '').trim() || 'Abierta';
              const active = (parts[3] || '').trim() === 'sí' || (parts[3] || '').trim() === 'yes';
              if (ssid && !nets.some(n => n.ssid === ssid)) {
                nets.push({ ssid, signal, security, connected: active });
              }
            });

            const volMatch = (volRes.stdout || '').match(/Volume:\s+([0-9.]+)/);
            const volPct = volMatch ? Math.round(parseFloat(volMatch[1]) * 100) : 75;
            const isMuted = (volRes.stdout || '').includes('[MUTED]');

            const battLines = (battRes.stdout || '').trim().split('\n');
            const battPct = parseInt(battLines[0] || '100', 10);
            const isCharging = (battLines[1] || '').trim() === 'Charging';

            res.statusCode = 200;
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify({
              wifi: { enabled: true, nets },
              volume: { pct: volPct, muted: isMuted },
              battery: { pct: battPct, charging: isCharging }
            }));
          } catch (err) {
            res.statusCode = 500;
            res.end(JSON.stringify({ error: err.message }));
          }
        });

        // Recarga EN TIEMPO REAL en la barra nativa GTK (<100ms)
        server.middlewares.use('/api/live-style', async (req, res) => {
          if (req.method === 'POST') {
            let body = '';
            req.on('data', chunk => { body += chunk; });
            req.on('end', () => {
              try {
                const data = JSON.parse(body);
                const home = os.homedir();
                const configDir = path.join(home, '.config/loon-bar');
                const customCssPath = path.join(configDir, 'custom.css');
                const mpvDir = path.join(home, '.config/mpvpaper');
                const accentPath = path.join(mpvDir, 'accent.txt');

                if (!fs.existsSync(configDir)) {
                  fs.mkdirSync(configDir, { recursive: true });
                }

                if (data.css) {
                  fs.writeFileSync(customCssPath, data.css, 'utf8');
                }

                if (data.accent && /^#[0-9a-fA-F]{6}$/.test(data.accent)) {
                  if (!fs.existsSync(mpvDir)) {
                    fs.mkdirSync(mpvDir, { recursive: true });
                  }
                  fs.writeFileSync(accentPath, data.accent, 'utf8');
                }

                res.statusCode = 200;
                res.setHeader('Content-Type', 'application/json');
                res.end(JSON.stringify({ success: true }));
              } catch (err) {
                res.statusCode = 500;
                res.end(JSON.stringify({ error: err.message }));
              }
            });
          }
        });

        // Sincronización permanente en theme.rs
        server.middlewares.use('/api/sync-theme', async (req, res) => {
          if (req.method === 'POST') {
            let body = '';
            req.on('data', chunk => { body += chunk; });
            req.on('end', () => {
              try {
                const data = JSON.parse(body);
                const themeRsPath = path.resolve(import.meta.dirname, '../src/theme.rs');

                let content = fs.readFileSync(themeRsPath, 'utf8');

                if (data.accent) {
                  content = content.replace(
                    /\.unwrap_or_else\(\|\| "#[0-9a-fA-F]{6}"\.to_string\(\)\)/,
                    `.unwrap_or_else(|| "${data.accent}".to_string())`
                  );
                }

                if (data.underbarHeight || data.barOpacity || data.itemMargin) {
                  const underbar = data.underbarHeight || 3;
                  const opacity = data.barOpacity || '0.94';
                  const margin = data.itemMargin || 2;

                  content = content.replace(
                    /background-color: rgba\(16, 16, 16, [0-9.]+\);/,
                    `background-color: rgba(16, 16, 16, ${opacity});`
                  );

                  content = content.replace(
                    /border-bottom: [0-9]+px solid rgba\(255, 255, 255, 0.35\);/g,
                    `border-bottom: ${underbar}px solid rgba(255, 255, 255, 0.35);`
                  );

                  content = content.replace(
                    /border-bottom: [0-9]+px solid @accent;/g,
                    `border-bottom: ${underbar}px solid @accent;`
                  );

                  content = content.replace(
                    /border-bottom: [0-9]+px solid @accent-hover;/g,
                    `border-bottom: ${underbar}px solid @accent-hover;`
                  );

                  content = content.replace(
                    /margin: 0 [0-9]+px;/g,
                    `margin: 0 ${margin}px;`
                  );
                }

                fs.writeFileSync(themeRsPath, content, 'utf8');

                res.statusCode = 200;
                res.setHeader('Content-Type', 'application/json');
                res.end(JSON.stringify({ success: true, message: 'theme.rs actualizado exitosamente' }));
              } catch (err) {
                res.statusCode = 500;
                res.end(JSON.stringify({ error: err.message }));
              }
            });
          }
        });
      }
    }
  ]
});
