# Módulo "wayland/dms-greeter": greeter DankMaterialShell (DankGreeter).
# Pantalla de login sobre el compositor niri. Se registra en wayland/
# porque depende del compositor instalado a nivel de sistema.
#
# Config fina del tema en: ~/.config/DankMaterialShell/settings.json
{ config, lib, pkgs, ... }:

{
  services.displayManager.dms-greeter = {
    enable = true;
    # Compositor del greeter: debe estar instalado vía NixOS (no home-manager).
    compositor.name = "niri";
    # Sincroniza el tema de DankMaterialShell del usuario con el greeter.
    configHome = "/home/loonbac";
  };

  # Settings versionados del greeter: el greeter lee /var/lib/dms-greeter/settings.json
  # (blockWrites = true, solo lectura). Se instala declarativamente y se enlaza
  # al cache dir que crea el paquete dms-shell.
  environment.etc."dms-greeter/settings.json".source = ./settings.json;

  systemd.tmpfiles.rules = [
    "L+ /var/lib/dms-greeter/settings.json - - - - /etc/dms-greeter/settings.json"
  ];

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

      # Cuenta de usuario para AccountsService: IconFile apuntando al icono
      # publicado. Sin esto, el daemon reporta ~/.face (no legible por el
      # greeter, que corre como usuario dms-greeter).
      mkdir -p /var/lib/AccountsService/users
      cat > /var/lib/AccountsService/users/loonbac <<'EOF'
[User]
SystemAccount=false
IconFile=/var/lib/AccountsService/icons/loonbac
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
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils pkgs.imagemagick ];
    script = ''
      mkdir -p /var/lib/dms-greeter
      state="/home/loonbac/.config/mpvpaper/backdrop.txt"
      wallpaper=""
      if [ -f "$state" ]; then
        name="$(cat "$state")"
        [ -f "/home/loonbac/Pictures/Wallpaper/$name" ] && wallpaper="/home/loonbac/Pictures/Wallpaper/$name"
      fi
      [ -z "$wallpaper" ] && wallpaper="$(ls /home/loonbac/Pictures/Wallpaper/*.{png,jpg,jpeg,webp} 2>/dev/null | head -n1)"
      if [ -n "$wallpaper" ]; then
        magick "$wallpaper" -resize "1920x1080^" -gravity center -extent 1920x1080 \
          -quality 85 /var/lib/dms-greeter/greeter_wallpaper_override.jpg
        chmod 644 /var/lib/dms-greeter/greeter_wallpaper_override.jpg
      fi
    '';
  };
}
