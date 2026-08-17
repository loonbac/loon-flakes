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
}
