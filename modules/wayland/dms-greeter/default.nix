# Módulo "wayland/dms-greeter": greeter DankMaterialShell (DankGreeter).
# Pantalla de login sobre el compositor niri. Se registra en wayland/
# porque depende del compositor instalado a nivel de sistema.
#
# Config fina del tema en: ~/.config/DankMaterialShell/settings.json
{ config, lib, pkgs, ... }:

let
  fallbackWallpaper = pkgs.runCommand "dms-greeter-fallback.png" {
    nativeBuildInputs = [ pkgs.imagemagick ];
  } ''
    magick -size 1920x1080 'xc:#11181A' "PNG:$out"
  '';

  greeterColorsTemplate = pkgs.writeText "dms-greeter-colors.json" ''
    {
      "colors": {
        "dark": {
          "primary": "{{colors.primary.dark.hex}}",
          "on_primary": "{{colors.on_primary.dark.hex}}",
          "primary_container": "{{colors.primary_container.dark.hex}}",
          "secondary": "{{colors.secondary.dark.hex}}",
          "surface": "{{colors.surface.dark.hex}}",
          "on_background": "{{colors.on_background.dark.hex}}",
          "surface_variant": "{{colors.surface_variant.dark.hex}}",
          "on_surface_variant": "{{colors.on_surface_variant.dark.hex}}",
          "surface_tint": "{{colors.surface_tint.dark.hex}}",
          "background": "{{colors.background.dark.hex}}",
          "outline": "{{colors.outline.dark.hex}}",
          "surface_container": "{{colors.surface_container.dark.hex}}",
          "surface_container_high": "{{colors.surface_container_high.dark.hex}}",
          "surface_container_highest": "{{colors.surface_container_highest.dark.hex}}"
        },
        "light": {
          "primary": "{{colors.primary.light.hex}}",
          "on_primary": "{{colors.on_primary.light.hex}}",
          "primary_container": "{{colors.primary_container.light.hex}}",
          "secondary": "{{colors.secondary.light.hex}}",
          "surface": "{{colors.surface.light.hex}}",
          "on_background": "{{colors.on_background.light.hex}}",
          "surface_variant": "{{colors.surface_variant.light.hex}}",
          "on_surface_variant": "{{colors.on_surface_variant.light.hex}}",
          "surface_tint": "{{colors.surface_tint.light.hex}}",
          "background": "{{colors.background.light.hex}}",
          "outline": "{{colors.outline.light.hex}}",
          "surface_container": "{{colors.surface_container.light.hex}}",
          "surface_container_high": "{{colors.surface_container_high.light.hex}}",
          "surface_container_highest": "{{colors.surface_container_highest.light.hex}}"
        }
      }
    }
  '';

  greeterMatugenConfig = pkgs.writeText "dms-greeter-matugen.toml" ''
    [config]

    [templates.dms-greeter]
    input_path = '${greeterColorsTemplate}'
    output_path = '/var/lib/dms-greeter/colors.json'
  '';
in
{
  services.displayManager.dms-greeter = {
    enable = true;
    # Compositor del greeter: debe estar instalado vía NixOS (no home-manager).
    compositor.name = "niri";
  };

  # Una actualización nunca debe parar greetd mientras niri ocupa el seat. Si
  # eso sucede, el greeter nuevo toma DRM pero el niri anterior sigue vivo en
  # el user manager; los siguientes logins encuentran niri.service ya activo y
  # vuelven inmediatamente al greeter. Los cambios del greeter entran al boot.
  systemd.services.greetd = {
    restartIfChanged = false;
    stopIfChanged = false;
    unitConfig.RefuseManualStop = true;
  };

  # El preStart de dms-greeter necesita modificar/chown settings.json. Antes
  # era un symlink a /etc (store de solo lectura), lo que generaba errores en
  # cada arranque. Mantener una copia real también permite una migración limpia
  # desde las generaciones antiguas que ya crearon ese symlink.
  system.activationScripts.dmsGreeterSettings = {
    deps = [ "users" "groups" ];
    text = ''
      ${pkgs.coreutils}/bin/install -d -m 0755 -o dms-greeter -g dms-greeter \
        /var/lib/dms-greeter
      if [ -L /var/lib/dms-greeter/settings.json ]; then
        ${pkgs.coreutils}/bin/unlink /var/lib/dms-greeter/settings.json
      fi
      ${pkgs.coreutils}/bin/install -m 0644 -o dms-greeter -g dms-greeter \
        ${./settings.json} /var/lib/dms-greeter/settings.json
    '';
  };

  # --- Foto de perfil en el login (AccountsService) ---
  # El greeter consulta org.freedesktop.Accounts (IconFile del usuario) por D-Bus.
  # Se activa el daemon y se publica la imagen como icono del usuario.
  services.accounts-daemon.enable = true;

  # Si el usuario tiene ~/profile.* (p.ej. profile.jpeg) se usa como icono.
  # AccountsService expone /var/lib/AccountsService/icons/<user> como IconFile.
  systemd.services.publish-profile-icon = {
    description = "Publica la foto de perfil en AccountsService";
    wantedBy = [ "multi-user.target" ];
    before = [ "accounts-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils pkgs.imagemagick ];
    script = ''
      # Publica la foto como icono del usuario (legible por dms-greeter).
      # AccountsService rechaza archivos demasiado grandes (>1MB), así que
      # se redimensiona a 512px (JPEG, <100KB típicamente).
      mkdir -p /var/lib/AccountsService/icons
      profile=$(ls /home/loonbac/profile.* 2>/dev/null | head -n1)
      if [ -n "$profile" ]; then
        magick "$profile" -resize "512x512^" -gravity center -extent 512x512 \
          -quality 85 /var/lib/AccountsService/icons/loonbac
        chmod 644 /var/lib/AccountsService/icons/loonbac
      fi

      # Cuenta de usuario para AccountsService: Icon apuntando al icono
      # publicado. Sin esto, el daemon reporta ~/.face (no legible por el
      # greeter, que corre como usuario dms-greeter). La clave correcta del
      # archivo de usuario es "Icon=" (como escribe SetIconFile por D-Bus),
      # no "IconFile=".
      mkdir -p /var/lib/AccountsService/users
      cat > /var/lib/AccountsService/users/loonbac <<'EOF'
[User]
SystemAccount=false
Icon=/var/lib/AccountsService/icons/loonbac
EOF
    '';
  };

  # --- Fondo del greeter: la imagen del backdrop (detrás del video animado) ---
  # El greeter usa greeter_wallpaper_override.jpg en su cache dir cuando
  # greeterWallpaperPath está seteado en settings.json (declarado arriba).
  # Se copia el wallpaper estático actual (state de niri-backdrop) convertido
  # a JPEG; si cambias el fondo con 'niri-backdrop set', se actualiza en el
  # próximo arranque (o reiniciando este servicio).
  systemd.services.publish-greeter-wallpaper = {
    description = "Publica el wallpaper del backdrop en el greeter";
    wantedBy = [ "multi-user.target" ];
    # Solo ordena el arranque. No usar requiredBy/Requires: detener este
    # oneshot durante un switch propaga la parada a greetd y expulsa la sesión.
    before = [ "greetd.service" ];
    restartIfChanged = false;
    stopIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils pkgs.imagemagick pkgs.matugen ];
    script = ''
      mkdir -p /var/lib/dms-greeter
      state="/home/loonbac/.config/mpvpaper/backdrop.txt"
      wallpaper=""
      if [ -f "$state" ]; then
        name="$(cat "$state")"
        [ -f "/home/loonbac/Pictures/Wallpaper/$name" ] && wallpaper="/home/loonbac/Pictures/Wallpaper/$name"
      fi
      [ -z "$wallpaper" ] && wallpaper="$(ls /home/loonbac/Pictures/Wallpaper/*.{png,jpg,jpeg,webp} 2>/dev/null | head -n1)"
      # Un home recién creado aún no tiene wallpapers. El fallback declarativo
      # permite que el greeter arranque y conserva el tema oscuro del sistema.
      [ -n "$wallpaper" ] || wallpaper="${fallbackWallpaper}"
      magick "$wallpaper" -resize "1920x1080^" -gravity center -extent 1920x1080 \
        -quality 85 /var/lib/dms-greeter/greeter_wallpaper_override.jpg
      chmod 644 /var/lib/dms-greeter/greeter_wallpaper_override.jpg
      matugen image "$wallpaper" --config ${greeterMatugenConfig} \
        --source-color-index 0 --quiet
      # El preStart upstream renombra este archivo a colors.json. Dejar ambas
      # rutas evita el warning de archivo inexistente y mantiene el arranque
      # idempotente.
      cp /var/lib/dms-greeter/colors.json /var/lib/dms-greeter/dms-colors.json
      chown dms-greeter:dms-greeter \
        /var/lib/dms-greeter/colors.json \
        /var/lib/dms-greeter/dms-colors.json
    '';
  };
}
