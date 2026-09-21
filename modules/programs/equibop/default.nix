# Módulo "programs/equibop": cliente Discord Equibop con fix de WebRTC.
#
# Con Tailscale (o cualquier VPN) activo, WebRTC se confunde y se bindea a la
# interfaz de la VPN, quedando el voice chat colgado en "DTLS Connecting".
# El fix (el mismo de Vesktop PR #1283): forzar la política de IP de WebRTC a
# "default_public_and_private_interfaces" para que use las interfaces públicas
# y privadas pero NO la de la VPN (comentario del propio código de Vesktop:
# "Switching to 'default_public_and_private_interfaces' may fix calls stuck
# at 'DTLS Connecting' when using VPNs, Tailscale, etc.").
#
# OJO: el valor "disable_non_proxied_udp" NO sirve — desactiva todo el UDP
# directo y deja el media en "RTC Connecting" sin poder conectar.
# OJO: una bandera de Chromium (--webrtc-ip-handling-policy=...) NO sirve aquí
# porque Equibop no la lee. El fix real es llamar a la API de Electron
# webContents.setWebRTCIPHandlingPolicy(...) desde el proceso main, igual que
# hace Vesktop. Por eso parcheamos el app.asar: se extrae, se inyecta el hook
# en dist/js/main.js y se reempaqueta.
{ config, lib, pkgs, ... }:

let
  obs-overlay = pkgs.callPackage ../../../pkgs/equibop-obs-overlay { };
  voice-normalizer = pkgs.callPackage ../../../pkgs/equibop-voice-normalizer { };
  mic-hotkey = pkgs.callPackage ../../../pkgs/equibop-mic-hotkey { };
  equibop-fixed = pkgs.equibop.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.asar pkgs.perl ];

    postFixup =
      (old.postFixup or "")
      + ''
        # Parchear el app.asar: inyectar el hook que fija la política WebRTC
        # en cada webContents creado (mismo fix que Vesktop PR #1283).
        asar extract "$out/opt/Equibop/resources/app.asar" "$TMPDIR/equibop-asar"
        cat >> "$TMPDIR/equibop-asar/dist/js/main.js" <<'PATCH'
        // Da a Equibop una identidad de audio propia en Linux. Chromium ejecuta
        // AudioService fuera del proceso por defecto y termina publicando todos
        // los clientes Electron como "Chromium". Al mantenerlo dentro del
        // proceso, Electron puede propagar el nombre real a Pulse/PipeWire.
        (() => {
          if (process.platform !== "linux") return;
          const { app } = require("electron");
          try { app.setDesktopName("equibop.desktop"); } catch (_) {}

          const disabled = new Set(
            app.commandLine.getSwitchValue("disable-features").split(",").filter(Boolean)
          );
          disabled.add("AudioServiceOutOfProcess");
          app.commandLine.removeSwitch("disable-features");
          app.commandLine.appendSwitch("disable-features", [...disabled].join(","));
        })();
        PATCH
        cat >> "$TMPDIR/equibop-asar/dist/js/main.js" <<'PATCH'
        require("electron").app.on("web-contents-created", (_e, c) => {
          try { c.setWebRTCIPHandlingPolicy("default_public_and_private_interfaces"); } catch (_) {}
        });
        PATCH
        cat >> "$TMPDIR/equibop-asar/dist/js/main.js" <<'PATCH'
        // En Wayland, desktopCapturer ya abre el portal del compositor y éste
        // devuelve una sola fuente autorizada. Equibop muestra después un
        // segundo modal propio sólo para confirmar calidad/audio. Sustituimos
        // su handler al terminar de arrancar para aceptar directamente la
        // fuente elegida en el portal de niri y evitar esa confirmación doble.
        //
        // Niri 26.04+ publica cada captura por IPC, incluido si el objetivo es
        // una ventana o una salida. Esto permite escoger automáticamente el
        // audio: sólo la aplicación de la ventana, o todo el sistema para una
        // pantalla. Equibop/Discord queda excluido para evitar eco.
        (() => {
          const isWayland = process.platform === "linux"
            && (process.env.XDG_SESSION_TYPE === "wayland" || process.env.WAYLAND_DISPLAY);
          if (!isWayland) return;

          const { execFile } = require("node:child_process");
          const { promisify } = require("node:util");
          const { setTimeout: delay } = require("node:timers/promises");
          const { app, BrowserWindow, desktopCapturer, session } = require("electron");
          const execFileAsync = promisify(execFile);

          const normalize = value => String(value || "")
            .toLowerCase()
            .normalize("NFKD")
            .replace(/[^a-z0-9]+/g, "");

          async function niriJson(command) {
            try {
              const { stdout } = await execFileAsync("${pkgs.niri}/bin/niri", ["msg", "-j", command]);
              return JSON.parse(stdout);
            } catch (error) {
              console.error("Could not read niri " + command, error);
              return [];
            }
          }

          function requestFrame(request) {
            // El frame que origina getDisplayMedia puede ser un subframe de
            // Discord sin el preload de Equibop. Ejecuta los bridges nativos
            // en el frame principal que sí expone VesktopNative.
            const windows = BrowserWindow.getAllWindows().filter(window => !window.isDestroyed());
            const mainWindow = windows.find(window =>
              /^https:\/\/(canary\.|ptb\.)?discord\.com\//.test(window.webContents.getURL())
            ) || windows.find(window => window.isVisible()) || windows[0];
            if (mainWindow) return mainWindow.webContents.mainFrame;
            if (request.frame && !request.frame.isDestroyed()) return request.frame;
            return null;
          }

          async function runInRenderer(frame, expression) {
            if (!frame || frame.isDestroyed()) return null;
            try {
              return await frame.executeJavaScript(expression, true);
            } catch (error) {
              console.error("Could not configure Equibop screen share audio", error);
              return null;
            }
          }

          function findNewCast(before, after) {
            const previous = new Set(before.map(cast => cast.stream_id));
            return after.find(cast => cast.kind === "PipeWire" && !previous.has(cast.stream_id))
              || [...after].reverse().find(cast => cast.kind === "PipeWire" && cast.is_active);
          }

          async function waitForCast(before) {
            // El cast sólo pasa a estar visible después de responderle a
            // getDisplayMedia. Dale tiempo al portal, pero nunca bloquees la
            // devolución del video esperando este dato.
            for (let attempt = 0; attempt < 50; attempt++) {
              const cast = findNewCast(before, await niriJson("casts"));
              if (cast) return cast;
              await delay(100);
            }
            return null;
          }

          function appAliases(appId) {
            const parts = String(appId || "").replace(/\.desktop$/i, "").split(/[.\/_-]+/);
            return new Set([normalize(appId), ...parts.map(normalize)].filter(part => part.length > 2));
          }

          function audioFilter(window, targets) {
            const aliases = appAliases(window.app_id);
            const title = normalize(window.title);
            let best = null;
            let bestScore = 0;

            for (const target of targets) {
              const binary = normalize(target["application.process.binary"]);
              const appName = normalize(target["application.name"]);
              const mediaName = normalize(target["media.name"]);
              let score = 0;

              if (aliases.has(binary)) score += 100;
              if (aliases.has(appName)) score += 80;
              if (binary && [...aliases].some(alias => alias.includes(binary) || binary.includes(alias))) score += 40;
              if (mediaName && title && (title.includes(mediaName) || mediaName.includes(title))) score += 60;

              if (score > bestScore) {
                best = target;
                bestScore = score;
              }
            }

            if (bestScore > 0) {
              const binary = best["application.process.binary"];
              const mediaName = best["media.name"];
              const normalizedMedia = normalize(mediaName);
              const mediaMatchesWindow = normalizedMedia && title
                && (title.includes(normalizedMedia) || normalizedMedia.includes(title));

              if (binary && mediaMatchesWindow) {
                return {
                  "application.process.binary": binary,
                  "media.name": mediaName
                };
              }
              if (binary) return { "application.process.binary": binary };
              if (best["application.name"]) return { "application.name": best["application.name"] };
            }

            // Si la aplicación todavía no reproduce sonido, venmic conservará
            // el filtro y enlazará el nodo cuando aparezca.
            return window.app_id ? { "application.process.binary": window.app_id } : null;
          }

          async function configureAudio(request, cast) {
            const frame = requestFrame(request);
            await runInRenderer(frame, "VesktopNative.virtmic.stop()");

            if (cast?.target?.Output) {
              const excluded = [
                { "application.process.id": String(process.pid) },
                { "application.process.binary": "equibop" },
                { "application.process.binary": "discord" },
                { "application.process.binary": "Discord" },
                { "application.process.binary": "vesktop" }
              ];
              const result = await runInRenderer(
                frame,
                "VesktopNative.virtmic.startSystem(" + JSON.stringify(excluded) + ")"
              );
              console.log("Equibop screen share system audio configured", result);
              return;
            }

            const windowId = cast?.target?.Window?.id;
            if (windowId == null) return;

            const windows = await niriJson("windows");
            const window = windows.find(candidate => String(candidate.id) === String(windowId));
            if (!window || ["equibop", "discord", "vesktop"].includes(normalize(window.app_id))) return;

            const listed = await runInRenderer(frame, "VesktopNative.virtmic.list()");
            const filter = audioFilter(window, listed?.ok ? listed.targets : []);
            if (filter) {
              const result = await runInRenderer(
                frame,
                "VesktopNative.virtmic.start(" + JSON.stringify(filter) + ")"
              );
              console.log("Equibop screen share window audio configured", filter, result);
            }
          }

          async function configureQuality(request) {
            const frame = requestFrame(request);
            const expression = `(() => {
              const saved = JSON.parse(localStorage.getItem("EquibopState") || "{}");
              const frameRate = Number(saved.screenshareQuality?.frameRate || 30);
              const resolution = Number(saved.screenshareQuality?.resolution || 720);
              const width = Math.round(resolution * 16 / 9);
              const common = Vencord?.Webpack?.Common;
              const connection = [...common.MediaEngineStore.getMediaEngine().connections]
                .find(item => item.streamUserId === common.UserStore.getCurrentUser().id);
              if (!connection?.videoStreamParameters?.[0]) {
                return { ok: false, reason: "stream connection not ready" };
              }
              const params = connection.videoStreamParameters[0];
              params.maxFrameRate = frameRate;
              params.maxResolution ||= { width: 0, height: 0 };
              params.maxResolution.width = width;
              params.maxResolution.height = resolution;
              return { ok: true, frameRate, width, height: resolution };
            })()`;
            const result = await runInRenderer(frame, expression);
            console.log("Equibop screen share quality configured", result);
          }

          app.whenReady().then(() => {
            session.defaultSession.setDisplayMediaRequestHandler(async (request, callback) => {
              console.log("Equibop niri screen share request received");
              const castsBefore = await niriJson("casts");
              const sources = await desktopCapturer.getSources({
                types: ["window", "screen"],
                thumbnailSize: { width: 0, height: 0 }
              }).catch(error => {
                console.error("Error in niri screen share portal", error);
                return null;
              });

              if (!sources?.[0]) {
                callback({});
                return;
              }

              // niri no publica el cast hasta que Electron acepta la fuente.
              // Responde primero; el wrapper del renderer crea mientras tanto
              // el audio del sistema y espera a que aparezca el dispositivo.
              callback({ video: sources[0] });

              void (async () => {
                const cast = await waitForCast(castsBefore);
                await configureQuality(request);
                if (cast?.target?.Window) {
                  await configureAudio(request, cast);
                } else if (cast?.target?.Output) {
                  // El renderer ya abrió una fuente estable con todo el audio
                  // del sistema. No la recrees después de que Discord haya
                  // obtenido su pista.
                  console.log("Equibop screen share system audio kept", cast.target.Output.name);
                } else {
                  console.error("Could not identify the niri cast; keeping system audio fallback");
                }
              })().catch(error => {
                console.error("Could not finish Equibop screen share setup", error);
              });
            });
          });
        })();
        PATCH

        # El modal normalmente inicializa currentSettings.contentHint. Como lo
        # omitimos, conserva su valor por defecto (movimiento) en el wrapper de
        # getDisplayMedia. El identificador previo está minificado y puede variar.
        if ! grep -Eq '\.contentHint=String\([[:alnum:]_$]+\?\.contentHint\)' \
          "$TMPDIR/equibop-asar/dist/js/renderer.js"; then
          echo "Equibop screenshare contentHint hook not found" >&2
          exit 1
        fi
        perl -0pi -e \
          's/\.contentHint=String\(([[:alnum:]_\$]+)\?\.contentHint\)/.contentHint=String($1?.contentHint??"motion")/' \
          "$TMPDIR/equibop-asar/dist/js/renderer.js"

        # Equibop sólo consulta una vez si venmic apareció. En PipeWire la
        # fuente virtual se anuncia de forma asíncrona, así que esa carrera
        # dejaba el video funcionando pero sin ninguna pista de audio. Crea un
        # fallback de audio del sistema tras aceptar el portal y espera hasta
        # tres segundos por el dispositivo. El handler de arriba lo limita a
        # la aplicación elegida posteriormente si se compartió una ventana.
        if ! grep -Fq 'async function t(){try{return(await navigator.mediaDevices.enumerateDevices()).find(({label:r})=>r==="vencord-screen-share")?.deviceId}catch{return null}}' \
          "$TMPDIR/equibop-asar/dist/js/renderer.js"; then
          echo "Equibop screenshare audio device lookup not found" >&2
          exit 1
        fi
        perl -0pi -e \
          's/async function t\(\)\{try\{return\(await navigator\.mediaDevices\.enumerateDevices\(\)\)\.find\(\(\{label:r\}\)=>r==="vencord-screen-share"\)\?\.deviceId\}catch\{return null\}\}/async function t(){for(let e=0;e<30;e++){try{let e=(await navigator.mediaDevices.enumerateDevices()).find(({label:r})=>r==="vencord-screen-share");if(e?.deviceId)return e.deviceId}catch{}await new Promise(e=>setTimeout(e,100))}return null}/' \
          "$TMPDIR/equibop-asar/dist/js/renderer.js"

        if ! grep -Fq 'let a=await e.call(this,o),r=await t(),' \
          "$TMPDIR/equibop-asar/dist/js/renderer.js"; then
          echo "Equibop getDisplayMedia audio hook not found" >&2
          exit 1
        fi
        perl -0pi -e \
          's/let a=await e\.call\(this,o\),r=await t\(\),/let a=await e.call(this,o);try{await VesktopNative.virtmic.startSystem([{"application.process.binary":"equibop"},{"application.name":"Equibop"},{"application.process.binary":"discord"},{"application.process.binary":"Discord"},{"application.process.binary":"vesktop"}])}catch(e){console.error("Could not start screen share system audio",e)}let r=await t(),/' \
          "$TMPDIR/equibop-asar/dist/js/renderer.js"

        cat ${../../../pkgs/equibop-obs-overlay/main.js} >> "$TMPDIR/equibop-asar/dist/js/main.js"
        cat ${../../../pkgs/equibop-obs-overlay/preload.js} >> "$TMPDIR/equibop-asar/dist/js/preload.js"
        install -Dm0644 ${../../../pkgs/equibop-obs-overlay/renderer.js} "$TMPDIR/equibop-asar/dist/js/obs-overlay-renderer.js"
        cat ${../../../pkgs/equibop-voice-normalizer/main.js} >> "$TMPDIR/equibop-asar/dist/js/main.js"
        cat ${../../../pkgs/equibop-voice-normalizer/preload.js} >> "$TMPDIR/equibop-asar/dist/js/preload.js"
        install -Dm0644 ${voice-normalizer}/share/equibop-voice-normalizer/renderer.js "$TMPDIR/equibop-asar/dist/js/voice-normalizer-renderer.js"
        cat ${../../../pkgs/equibop-mic-hotkey/equibop-hotkey-bridge.js} >> "$TMPDIR/equibop-asar/dist/js/main.js"

        asar pack "$TMPDIR/equibop-asar" "$out/opt/Equibop/resources/app.asar"

        # libvesktop se carga dinámicamente desde app.asar. Electron no ve
        # sus dependencias Nix por defecto, así que el tray nativo falla y
        # Waybar recibe el menú vacío de Electron. El wrapper garantiza que
        # dlopen encuentre tanto libstdc++ como GLib al arrancar Equibop.
        wrapProgram "$out/bin/equibop" \
          --set PULSE_PROP 'application.name=Equibop application.process.binary=equibop application.icon_name=equibop media.role=phone' \
          --prefix LD_LIBRARY_PATH : '${lib.makeLibraryPath [ pkgs.stdenv.cc.cc pkgs.glib pkgs.pipewire pkgs.pulseaudio ]}'

        # loon-launch es un servicio persistente. Si ejecuta Electron de forma
        # directa, Chromium puede crear zygotes antes de que la instancia se
        # mueva a su app-scope y dejarlos dentro del cgroup del launcher. Al
        # caer Equibop esos procesos quedan huérfanos y pueden entrar en un
        # bucle de CPU. El lanzador inicia primero la unidad dedicada; cuando
        # ya está activa, conserva el comportamiento single-instance normal
        # de Equibop para enfocar la ventana o reenviar una URI discord://.
        cat > "$out/bin/equibop-systemd-launch" <<EOF
        #!${pkgs.runtimeShell}
        if ${pkgs.systemd}/bin/systemctl --user --quiet is-active equibop.service; then
          exec "$out/bin/equibop" "\$@"
        fi

        ${pkgs.systemd}/bin/systemctl --user start equibop.service
        if [ "\$#" -gt 0 ]; then
          exec "$out/bin/equibop" "\$@"
        fi
        EOF
        chmod 0755 "$out/bin/equibop-systemd-launch"

        substituteInPlace "$out/share/applications/equibop.desktop" \
          --replace-fail 'Exec=equibop %U' 'Exec=equibop-systemd-launch %U'

      '';
  });
in
{
  environment.systemPackages = [ equibop-fixed obs-overlay voice-normalizer ];
  # Expone el renderer bajo una ruta estable. El proceso de Equibop vigila
  # este enlace y recarga el lector cuando un nixos-rebuild instala una
  # versión nueva, sin tener que reiniciar el cliente.
  environment.pathsToLink = [
    "/share/equibop-obs-overlay"
    "/share/equibop-voice-normalizer"
  ];

  # venmic expone esta fuente como el micrófono virtual de la transmisión.
  # No restaures un volumen antiguo del mezclador: debe nacer a ganancia
  # unitaria para que Discord reciba el audio de escritorio sin atenuación.
  services.pipewire.wireplumber.extraConfig."52-equibop-screen-share-volume" = {
    "stream.rules" = [
      {
        matches = [ { "node.name" = "vencord-screen-share"; } ];
        actions.update-props = {
          "state.default-volume" = 1.0;
          "state.restore-props" = false;
        };
      }
    ];
  };

  # El servidor sólo escucha 127.0.0.1:5123. Equibop deja el estado saneado
  # bajo XDG_RUNTIME_DIR y OBS carga el HTML desde localhost; nada se envía a
  # Discord, Reactive ni a un servicio externo.
  systemd.user.services.equibop-obs-overlay = {
    description = "Overlay local de voz de Equibop para OBS";
    wantedBy = [ "loon-niri-session.target" ];
    after = [ "niri.service" ];
    partOf = [ "loon-niri-session.target" ];
    serviceConfig = {
      ExecStart = "${obs-overlay}/bin/equibop-obs-overlay";
      Restart = "on-failure";
      RestartSec = "1s";
      Environment = [
        "HOME=/home/loonbac"
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
      ];
    };
  };

  # Mantiene todo el árbol de Electron dentro de un cgroup propio. Si el
  # proceso principal falla, systemd elimina también sus zygotes y reinicia el
  # mismo Equibop parcheado, sin tocar el perfil ni sus ajustes del usuario.
  systemd.user.services.equibop = {
    description = "Cliente Discord Equibop supervisado";
    wantedBy = [ "loon-niri-session.target" ];
    after = [ "niri.service" ];
    partOf = [ "loon-niri-session.target" ];
    serviceConfig = {
      ExecStart = "${equibop-fixed}/bin/equibop";
      Restart = "on-failure";
      RestartSec = "2s";
      KillMode = "control-group";
      TimeoutStopSec = "10s";
      Environment = [
        "HOME=/home/loonbac"
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
      ];
    };
  };

  # Niri no recibe los F13 que salen de la interfaz secundaria del Basilisk V3
  # en esta sesión Wayland. Este servicio lee sólo esa interfaz por evdev y
  # usa el socket privado de Equibop para llegar a su instancia ya abierta.
  # Si Equibop todavía no está abierto, usa su CLI como fallback.
  systemd.services.equibop-basilisk-mic-hotkey = {
    description = "F13 del Basilisk V3 para silenciar el micro de Equibop";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" ];
    serviceConfig = {
      ExecStart = "${mic-hotkey}/bin/equibop-mic-hotkey";
      Restart = "always";
      RestartSec = "2s";
    };
  };

  # Autostart gestionado por NixOS (mismo patrón que ghostty/niri):
  # se instala en /etc/equibop/ y un tmpfiles rule crea el symlink en el home.
  environment.etc."equibop/autostart.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Equibop
    Comment=Equibop autostart script
    Exec=equibop-systemd-launch
    StartupNotify=false
    Terminal=false
    Icon=equibop
  '';

  # Ruta absoluta: systemd no expande "~" en tmpfiles.
  systemd.tmpfiles.rules = [
    "d /home/loonbac/.config/autostart 0755 loonbac users -"
    "L+ /home/loonbac/.config/autostart/equibop.desktop - - - - /etc/equibop/autostart.desktop"
  ];
}
