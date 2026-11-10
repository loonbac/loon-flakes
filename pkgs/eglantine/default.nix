# Paquete "eglantine": launcher estable de Eglantine, emulador de Nintendo
# Switch 2 (fork de Eden/Yuzu/Sudachi, GPL-3.0).
#
# Por qué es un launcher mutable y NO una derivación con fetchurl + sha256:
# la política de versiones del repo (AGENTS.md) prohíbe crear pins manuales
# nuevos y pide preferir, en orden: paquete de nixpkgs, instalador mutable
# oficial o metadatos actualizados automáticamente. Para Eglantine:
#   1. no está en nixpkgs (sí lo están `eden` y `citron`, que son otros
#      proyectos distintos),
#   2. no hay instalador ni actualizador para Linux: publican el propio
#      ejecutable (AppImage autocontenido o tar.gz con libs del sistema),
#   3. no hay CI de actualización de metadatos en este repo.
# Así que el binario vive fuera del store, como el resto de software mutable
# de esta máquina (mismo criterio que `codex` en packages.nix): Nix instala
# el comando, el AppImage se descarga a ~/.local/share/eglantine/ solo si
# falta, y NUNCA se actualiza en un rebuild ni en un arranque. Refrescarlo es
# una orden explícita: `eglantine --update`.
#
# La URL no contiene versión: GitHub redirige
#   /releases/latest/download/<asset>
# al asset de la última release publicada, así que el repo no fija ningún
# número de release ni una RC concreta.
#
# El AppImage no corre tal cual en NixOS (runtime FHS ausente → stub-ld), por
# eso se lanza con `appimage-run` de nixpkgs, que le aporta ese entorno.
{ lib, writeShellApplication, appimage-run, curl, symlinkJoin }:

let
  appImageUrl =
    "https://github.com/Eglantine-Community/Eglantine/releases/latest/download/eglantine-linux-x86_64-pgo.AppImage";

  launcher = writeShellApplication {
    name = "eglantine";
    runtimeInputs = [ appimage-run curl ];
    text = ''
      # Directorio propio del launcher, SEPARADO de los datos del emulador:
      # Eglantine usa ~/.local/share/eglantine para sus nand/keys/sdmc, así
      # que guardar aquí dentro el AppImage mezclaría nuestro archivo con su
      # árbol de datos (y un "borrar datos" se llevaría la imagen por delante).
      data_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/eglantine-appimage"
      app="$data_dir/eglantine.AppImage"
      url="${appImageUrl}"

      # `--update` solo como primer argumento: es nuestro flag, no del
      # emulador. Fuerza la descarga sin tocar nada más.
      force=0
      if [ "''${1:-}" = "--update" ]; then
        force=1
        shift
      fi

      if [ "$force" -eq 1 ] || [ ! -x "$app" ]; then
        mkdir -p "$data_dir"
        tmp="$app.tmp.$$"
        trap 'rm -f "$tmp"' EXIT
        echo "eglantine: descargando el AppImage de la última release..." >&2
        curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"
        chmod 0755 "$tmp"
        mv -f "$tmp" "$app"
        trap - EXIT
        # --update invalida la nota de versión anterior.
        rm -f "$data_dir/release"
        echo "eglantine: descarga completada" >&2
      fi

      # Qué release está instalada. El asset redirige a un CDN cuya URL no
      # lleva el tag, así que se lee el redirect de /releases/latest: una
      # petición HEAD, sin API, sin token y sin fijar versión en el repo.
      if [ ! -f "$data_dir/release" ]; then
        latest="$(curl -fsIL -o /dev/null -w '%{url_effective}' \
          'https://github.com/Eglantine-Community/Eglantine/releases/latest' || true)"
        tag="$(printf '%s' "$latest" | sed -n 's#.*/tag/\([^/]*\)$#\1#p')"
        printf '%s\n' "''${tag:-desconocida}" > "$data_dir/release"
        echo "eglantine: instalado ($tag)" >&2
      fi

      exec appimage-run "$app" "$@"
    '';
  };
in
symlinkJoin {
  name = "eglantine";
  paths = [ launcher ];

  # El AppImage trae su propio .desktop, pero vive dentro de la imagen y solo
  # sería visible tras extraerla. Este entra al catálogo del sistema para que
  # aparezca en loon-launch (Super+Space) y en el buscador.
  postBuild = ''
    mkdir -p "$out/share/applications"
    cat > "$out/share/applications/eglantine.desktop" <<EOF
    [Desktop Entry]
    Type=Application
    Name=Eglantine
    GenericName=Nintendo Switch 2 emulator
    Comment=Run Nintendo Switch and Switch 2 games
    Exec=$out/bin/eglantine %U
    Icon=joystick
    Terminal=false
    Categories=Game;Emulator;
    EOF
  '';

  meta = {
    description = "Emulador de Nintendo Switch 2 (Eglantine) como launcher mutable";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
  };
}
