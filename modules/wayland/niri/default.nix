# Módulo "wayland/niri": compositor Wayland niri (scrollable-tiling).
# Cada compositor/servicio en su propia carpeta, como un crate.
#
# La configuración (config.kdl) se gestiona desde NixOS:
#   - Se instala en /etc/niri/config.kdl (fuente de verdad, versionada).
#   - Un tmpfiles rule crea ~/.config/niri/config.kdl como symlink a
#     /etc/niri/config.kdl (niri da prioridad al home, por eso el symlink).
# Edita el archivo config.kdl de este repo y corre `rebuild`.
{ config, lib, pkgs, ... }:

let
  keyboardLayout = config.services.xserver.xkb.layout;
  isNixosPc = config.networking.hostName == "nixos-pc";
  isLoonLaptop = config.networking.hostName == "loon-laptop";
  brightnessCommand =
    if isLoonLaptop then "screen-brightness"
    else if isNixosPc then "ddc-brightness"
    else null;
  hostOutputConfig = lib.optionalString isNixosPc ''
    // Configuración editable generada por nwg-displays en nixos-pc.
    include "monitor.kdl"
  '';
  hostBacklightBinds = lib.optionalString (brightnessCommand != null) ''
    // Brillo con Fn+F6 / Fn+F7 usando el backend específico del host.
    XF86MonBrightnessDown { spawn-sh "${brightnessCommand} down 10"; }
    XF86MonBrightnessUp { spawn-sh "${brightnessCommand} up 10"; }
  '';

  defaultMonitorConfig = pkgs.writeText "niri-default-monitor.kdl" ''
    // Valor inicial; nwg-displays puede reemplazar este archivo.
    output "HDMI-A-1" {
        hot-corners {
            off
        }
    }

    output "DP-2" {
        mode "1920x1080@144.002"
    }
  '';

  # El tema GTK puede conservar en caché la ausencia de un icono cuando una
  # aplicación se instala con la sesión ya iniciada. Una ruta absoluta evita
  # ese falso negativo y sigue apuntando al recurso del propio paquete.
  nwgDisplays = pkgs.nwg-displays.overrideAttrs (oldAttrs: {
    postInstall = (oldAttrs.postInstall or "") + ''
      substituteInPlace $out/share/applications/nwg-displays.desktop \
        --replace-fail \
          'Icon=nwg-displays' \
          "Icon=$out/share/icons/hicolor/scalable/apps/nwg-displays.svg"
    '';
  });

  # La plantilla permanece como KDL válido (y se puede validar directamente),
  # pero cada host recibe el mismo layout que X11 y la consola, además de sus
  # ajustes específicos de monitor.
  niriConfigDir = pkgs.runCommand "niri-config" { } ''
    mkdir "$out"
    substitute ${./config.kdl} "$out/config.kdl" \
      --replace-fail \
        'layout "es" // HOST_KEYBOARD_LAYOUT' \
        'layout "${keyboardLayout}" // HOST_KEYBOARD_LAYOUT' \
      --replace-fail \
        '// HOST_OUTPUT_CONFIG' \
        ${lib.escapeShellArg hostOutputConfig} \
      --replace-fail \
        '// HOST_BACKLIGHT_BINDS' \
        ${lib.escapeShellArg hostBacklightBinds}
    ${lib.optionalString isNixosPc ''
      cp ${defaultMonitorConfig} "$out/monitor.kdl"
    ''}
  '';
  niriConfig = "${niriConfigDir}/config.kdl";

  defaultAccent = pkgs.writeText "niri-default-accent.kdl" ''
    layout {
        border {
            active-color "#5e81ac"
        }
    }
  '';

  # Convierte `niri validate` en una dependencia del sistema. La prueba usa
  # un HOME vacío y crea únicamente el archivo dinámico que tmpfiles garantiza,
  # por lo que detecta tanto errores KDL como includes ausentes en instalaciones
  # nuevas antes de que se pueda activar una generación rota.
  niriConfigCheck = pkgs.runCommand "niri-config-check" {
    nativeBuildInputs = [ pkgs.niri ];
  } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME/.config/niri"
    cp ${defaultAccent} "$HOME/.config/niri/accent.kdl"
    niri validate --config ${niriConfig}
    touch "$out"
  '';
in

{
  imports = [ ./session-services.nix ];

  # GUI para configurar las salidas de Niri. Se instala solo en el PC de
  # escritorio; la laptop conserva su configuración y paquetes actuales.
  environment.systemPackages = lib.optionals isNixosPc [ nwgDisplays ];

  programs.niri = {
    enable = true;
    # Parcheamos niri-session envolviendo el paquete con symlinkJoin para no recompilar niri desde código fuente.
    # Esto silencia el aviso de deprecación en stderr de `systemctl --user import-environment`.
    package = (pkgs.symlinkJoin {
      name = "niri-patched";
      paths = [ pkgs.niri ];
      postBuild = ''
        rm $out/bin/niri-session
        substitute ${pkgs.niri}/bin/niri-session $out/bin/niri-session \
          --replace-fail 'systemctl --user import-environment' 'systemctl --user import-environment PATH DBUS_SESSION_BUS_ADDRESS XDG_DATA_DIRS XDG_CONFIG_DIRS XDG_RUNTIME_DIR XAUTHORITY LANG LC_ALL LC_CTYPE 2>/dev/null'
        chmod +x $out/bin/niri-session
      '';
    }).overrideAttrs (oldAttrs: {
      passthru = (pkgs.niri.passthru or { }) // {
        providedSessions = pkgs.niri.providedSessions or [ "niri" ];
      };
    });
  };

  # Config gestionada por NixOS: niri la lee como fallback desde /etc/niri.
  environment.etc."niri/config.kdl".source = niriConfig;

  system.extraDependencies = [ niriConfigCheck ];

  # Fuerza que la config del home sea un symlink a la gestionada,
  # reemplazando el default que niri genera en el primer arranque.
  # Ruta absoluta: systemd no expande "~" en tmpfiles.
  systemd.tmpfiles.rules = [
    # En un home recién creado no existe ~/.config/niri. Debe declararse antes
    # de crear los archivos; confiar en que una sesión anterior lo haya creado
    # hacía que `niri validate` fallara en instalaciones limpias.
    "d /home/loonbac/.config/niri 0755 loonbac users -"
    "L+ /home/loonbac/.config/niri/config.kdl - - - - /etc/niri/config.kdl"
    # Acento dinámico: lo escribe accent-wallpaper. `C` copia el default
    # solamente si el destino no existe y permite usar un archivo multilínea
    # sin introducir líneas inválidas en la configuración de tmpfiles.
    "C /home/loonbac/.config/niri/accent.kdl 0644 loonbac users - ${defaultAccent}"
  ] ++ lib.optionals isNixosPc [
    # Archivo persistente y escribible que nwg-displays actualiza. `C` instala
    # el modo inicial de 144 Hz solo cuando aún no existe, sin pisar cambios.
    "C /home/loonbac/.config/niri/monitor.kdl 0644 loonbac users - ${defaultMonitorConfig}"
    # El include relativo que nwg-displays reconoce se resuelve desde /etc/niri;
    # este enlace lo conecta al archivo persistente del usuario.
    "L+ /etc/niri/monitor.kdl - - - - /home/loonbac/.config/niri/monitor.kdl"
  ];
}
