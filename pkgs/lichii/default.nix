# Paquete "lichii": launcher estable de Lichii, emulador experimental de
# Nintendo Switch y Switch 2 (fork de Eglantine/Eden/Yuzu/Sudachi, GPL-3.0).
#
# Mismo criterio que pkgs/eglantine (ver allí el detalle de la política de
# versiones): no está en nixpkgs, el proyecto no publica instalador para Linux
# (solo el AppImage autocontenido y un tar.gz con libs del sistema) y no hay CI
# de metadatos en este repo. Por tanto launcher mutable: Nix instala el
# comando, el AppImage se descarga a ~/.local/share/lichii-appimage/ solo si
# falta, y NUNCA se actualiza en un rebuild ni en un arranque. Refrescarlo es
# una orden explícita: `lichii --update`.
#
# La URL no contiene versión: GitHub redirige
#   /releases/latest/download/<asset>
# al asset de la última release publicada, así que el repo no fija ningún
# número de build (van por build-160, build-150... y suben varias veces al día).
#
# Se usa la variante PGO porque el emulador es CPU-bound y es la que publica el
# proyecto para x86_64 Linux (~137 MB frentes a ~110 MB de la normal).
#
# El AppImage no corre tal cual en NixOS (runtime FHS ausente → stub-ld), por
# eso se lanza con `appimage-run` de nixpkgs, que le aporta ese entorno.
{ lib, writeShellApplication, appimage-run, curl, symlinkJoin }:

let
  appImageUrl =
    "https://github.com/zortos293/Lichii/releases/latest/download/lichii-linux-x86_64-pgo.AppImage";

  launcher = writeShellApplication {
    name = "lichii";
    runtimeInputs = [ appimage-run curl ];
    text = ''
      # Directorio propio del launcher, SEPARADO de los datos del emulador:
      # Lichii usa ~/.local/share/lichii para sus nand/keys/sdmc, así que
      # guardar aquí dentro el AppImage mezclaría nuestro archivo con su árbol
      # de datos (y un "borrar datos" se llevaría la imagen por delante).
      data_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/lichii-appimage"
      app="$data_dir/lichii.AppImage"
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
        echo "lichii: descargando el AppImage de la última release..." >&2
        curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"
        chmod 0755 "$tmp"
        mv -f "$tmp" "$app"
        trap - EXIT
        # --update invalida la nota de versión anterior.
        rm -f "$data_dir/release"
        echo "lichii: descarga completada" >&2
      fi

      # Qué release está instalada. El asset redirige a un CDN cuya URL no
      # lleva el tag, así que se lee el redirect de /releases/latest: una
      # petición HEAD, sin API, sin token y sin fijar versión en el repo.
      if [ ! -f "$data_dir/release" ]; then
        latest="$(curl -fsIL -o /dev/null -w '%{url_effective}' \
          'https://github.com/zortos293/Lichii/releases/latest' || true)"
        tag="$(printf '%s' "$latest" | sed -n 's#.*/tag/\([^/]*\)$#\1#p')"
        printf '%s\n' "''${tag:-desconocida}" > "$data_dir/release"
        echo "lichii: instalado ($tag)" >&2
      fi

      exec appimage-run "$app" "$@"
    '';
  };
in
symlinkJoin {
  name = "lichii";
  paths = [ launcher ];

  # El AppImage trae su propio .desktop, pero vive dentro de la imagen y solo
  # sería visible tras extraerla. Este entra al catálogo del sistema para que
  # aparezca en loon-launch (Super+Space) y en el buscador.
  postBuild = ''
    mkdir -p "$out/share/applications"
    cat > "$out/share/applications/lichii.desktop" <<EOF
    [Desktop Entry]
    Type=Application
    Name=Lichii
    GenericName=Nintendo Switch 2 emulator
    Comment=Run Nintendo Switch and Switch 2 games
    Exec=$out/bin/lichii %U
    Icon=joystick
    Terminal=false
    Categories=Game;Emulator;
    EOF
  '';

  meta = {
    description = "Emulador experimental de Nintendo Switch y Switch 2 (Lichii) como launcher mutable";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
  };
}
