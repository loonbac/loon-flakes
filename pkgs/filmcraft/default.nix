# Paquete "filmcraft": launcher estable de FilmCraft, editor de vídeo no
# lineal profesional escrito en Rust (MIT OR Apache-2.0, del equipo ArtCraft).
#
# Mismo criterio que pkgs/eglantine y pkgs/lichii (ver allí el detalle de la
# política de versiones): no está en nixpkgs, y aunque publican AppImage, .deb,
# .rpm, flatpak, .pkg.tar.zst y tarball para Linux, ninguno de esos formatos se
# instala tal cual en NixOS. Por tanto launcher mutable: Nix instala el comando,
# el AppImage se descarga a ~/.local/share/filmcraft-appimage/ solo si falta, y
# NUNCA se actualiza en un rebuild ni en un arranque. Refrescarlo es una orden
# explícita: `filmcraft --update`.
#
# Diferencia con eglantine/lichii: esos proyectos nombran su asset sin versión
# (p. ej. `lichii-linux-x86_64-pgo.AppImage`), así que
#   /releases/latest/download/<asset>
# resuelve sin fijar nada. Aquí los assets SÍ llevan el número
# (`filmcraft-0.20.1-linux-x86_64.AppImage`), así que una URL con nombre fijo
# obligaría a fijar la release en el repo, que es justo lo que prohíbe la
# política. La salida sin pin es resolver el asset en tiempo de descarga: la API
# pública de GitHub entrega el browser_download_url de la última release, y si
# esa ruta falla se cae al tag que devuelve el redirect de /releases/latest
# (mismo truco que usan eglantine/lichii para anotar la versión instalada).
# En ningún caso el número de versión viaja dentro de este archivo.
#
# El AppImage no corre tal cual en NixOS (runtime FHS ausente → stub-ld), por
# eso se lanza con `appimage-run` de nixpkgs, que le aporta ese entorno.
{ lib, writeShellApplication, appimage-run, curl, jq, symlinkJoin }:

let
  latestApi = "https://api.github.com/repos/storytold/filmcraft/releases/latest";
  releasesLatest = "https://github.com/storytold/filmcraft/releases/latest";

  launcher = writeShellApplication {
    name = "filmcraft";
    runtimeInputs = [ appimage-run curl jq ];
    text = ''
      # Directorio propio del launcher, SEPARADO de los proyectos del editor:
      # FilmCraft guarda sus .fcproj, autosaves y caché en otros sitios, pero
      # aun así la imagen se queda aquí para que un "borrar datos" de la app no
      # se lleve por delante el binario (mismo motivo que en eglantine/lichii).
      data_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/filmcraft-appimage"
      app="$data_dir/filmcraft.AppImage"

      # `--update` solo como primer argumento: es nuestro flag, no del editor.
      # Fuerza la descarga de la última release sin tocar nada más.
      force=0
      if [ "''${1:-}" = "--update" ]; then
        force=1
        shift
      fi

      # URL del AppImage de x86_64 de la última release, sin versión escrita en
      # el repo. La API va primero; el redirect va de respaldo por si la API
      # falla (rate limit sin token: 60 peticiones/hora por IP, y esto solo se
      # consulta al instalar o al actualizar, nunca en cada arranque).
      resolve_url() {
        url="$(curl -fsSL --retry 3 "${latestApi}" \
          | jq -r '[.assets[]? | .browser_download_url
                    | select(test("filmcraft-[0-9.]+-linux-x86_64\\.AppImage$"))][0] // empty' \
          || true)"
        if [ -n "$url" ]; then
          printf '%s\n' "$url"
          return 0
        fi

        latest="$(curl -fsIL -o /dev/null -w '%{url_effective}' \
          "${releasesLatest}" || true)"
        tag="$(printf '%s' "$latest" | sed -n 's#.*/tag/\([^/]*\)$#\1#p')"
        if [ -z "$tag" ]; then
          return 1
        fi
        printf '%s\n' "https://github.com/storytold/filmcraft/releases/download/$tag/filmcraft-''${tag#v}-linux-x86_64.AppImage"
      }

      if [ "$force" -eq 1 ] || [ ! -x "$app" ]; then
        mkdir -p "$data_dir"
        if ! url="$(resolve_url)"; then
          echo "filmcraft: no se pudo resolver la última release (¿sin red?)" >&2
          exit 1
        fi
        tmp="$app.tmp.$$"
        trap 'rm -f "$tmp"' EXIT
        echo "filmcraft: descargando el AppImage de la última release..." >&2
        curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"
        chmod 0755 "$tmp"
        mv -f "$tmp" "$app"
        trap - EXIT
        # --update invalida la nota de versión anterior.
        rm -f "$data_dir/release"
        echo "filmcraft: descarga completada" >&2
      fi

      # Icono del .desktop: está dentro de la imagen y no es visible sin
      # extraerla, así que se copia el PNG del repo a los iconos del usuario.
      # Secundario: si falla (sin red, ruta movida) el lanzador sigue siendo
      # usable y el .desktop cae al icono genérico del tema.
      icon_name="ai.storyteller.filmcraft"
      icon_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
      icon="$icon_dir/$icon_name.png"
      if [ ! -f "$icon" ]; then
        mkdir -p "$icon_dir"
        if curl -fsSL --retry 2 -o "$icon.tmp.$$" \
          "https://raw.githubusercontent.com/storytold/filmcraft/main/assets/app-icon/hicolor/256x256/apps/$icon_name.png"; then
          mv -f "$icon.tmp.$$" "$icon"
        else
          rm -f "$icon.tmp.$$"
        fi
      fi

      # Qué release está instalada. El asset redirige a un CDN cuya URL no
      # lleva el tag, así que se lee el redirect de /releases/latest: una
      # petición HEAD, sin API, sin token y sin fijar versión en el repo.
      if [ ! -f "$data_dir/release" ]; then
        latest="$(curl -fsIL -o /dev/null -w '%{url_effective}' \
          "${releasesLatest}" || true)"
        tag="$(printf '%s' "$latest" | sed -n 's#.*/tag/\([^/]*\)$#\1#p')"
        printf '%s\n' "''${tag:-desconocida}" > "$data_dir/release"
        echo "filmcraft: instalado ($tag)" >&2
      fi

      exec appimage-run "$app" "$@"
    '';
  };
in
symlinkJoin {
  name = "filmcraft";
  paths = [ launcher ];

  # El AppImage trae su propio .desktop, pero vive dentro de la imagen y solo
  # sería visible tras extraerla. Este entra al catálogo del sistema para que
  # aparezca en loon-launch (Super+Space) y en el buscador.
  #
  # El nombre del archivo es el app_id que reporta la ventana en Wayland
  # (verificado con `niri msg windows`): así el compositor asocia ventana,
  # icono y lanzador. Con un nombre distinto (p. ej. `filmcraft.desktop`) la
  # app aparecería en la barra con el icono genérico. Sin `MimeType`: no se
  # captura ninguna asociación de archivos, eso es responsabilidad de theme.nix.
  postBuild = ''
    mkdir -p "$out/share/applications"
    cat > "$out/share/applications/ai.storyteller.filmcraft.desktop" <<EOF
    [Desktop Entry]
    Type=Application
    Name=FilmCraft
    GenericName=Video Editor
    Comment=Non-linear video editor: editing, colour and sound
    Exec=$out/bin/filmcraft %F
    Icon=ai.storyteller.filmcraft
    Terminal=false
    StartupWMClass=ai.storyteller.filmcraft
    Categories=AudioVideo;AudioVideoEditing;Video;
    EOF
  '';

  meta = {
    description = "Editor de vídeo no lineal (FilmCraft) como launcher mutable";
    homepage = "https://github.com/storytold/filmcraft";
    license = with lib.licenses; [ mit asl20 ];
    platforms = lib.platforms.linux;
    mainProgram = "filmcraft";
  };
}
