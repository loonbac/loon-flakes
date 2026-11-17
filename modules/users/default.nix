# Módulo "users": definición de usuarios del sistema.
# Quién puede usar qué.
{ config, lib, pkgs, ... }:

{
  users.users."saito" = {
    isNormalUser = true;
    description = "Saito";
    # Grupos: networkmanager (GUI de red), wheel (sudo), storage (montaje sin sudo).
    extraGroups = [ "networkmanager" "wheel" "storage" ];
    # Paquetes instalados SOLO para este usuario (home-manager se integra aquí).
    packages = with pkgs; [ ];
    # Shell por defecto: fish.
    shell = pkgs.fish;
  };

  # npm global: instala en ~/.npm-global (el prefix del store de Nix es
  # inmutable y no se puede escribir). El PATH se gestiona en system/fish para
  # que los wrappers declarativos de NixOS tengan prioridad.
  systemd.tmpfiles.rules = [
    # Esqueleto mínimo de un home nuevo. Los módulos de aplicaciones declaran
    # sus subdirectorios concretos; estas bases evitan padres creados como root.
    "d /home/saito/.config 0755 saito users -"
    "d /home/saito/.local 0755 saito users -"
    "d /home/saito/.local/share 0755 saito users -"
    "d /home/saito/Pictures 0755 saito users -"
    "d /home/saito/Pictures/Wallpaper 0755 saito users -"
    "d /home/saito/Videos 0755 saito users -"
    "d /home/saito/Videos/Wallpapers 0755 saito users -"
    "d /home/saito/.npm-global 0755 saito users -"
    "d /home/saito/.npm-global/lib 0755 saito users -"
    "d /home/saito/.npm-global/bin 0755 saito users -"
  ];

  environment.sessionVariables = {
    # Tema de cursor por defecto del sistema (Win11OSX, Xcursor nativo).
    XCURSOR_THEME = "Win11OSX";
    XCURSOR_SIZE = "32";
    # Para apps GTK/Qt/Electron que leen su propio cursor.
    GTK_CURSOR_THEME = "Win11OSX";
    GTK_CURSOR_SIZE = "32";
    # GTK_THEME se quitó el 2026-11-08. Con él puesto, GTK3/GTK4 ignoran
    # `dconf gtk-theme` (el env manda sobre dconf), lo que bloqueaba cualquier
    # cambio de tema en caliente y de paso hacía que Adwaita-dark no resolviera
    # (verificó: dconf=Adwaita + GTK_THEME=Adwaita:dark => #353535, es decir
    # el env ganaba). Chromium/Equibop NO dependen de él: siguen
    # `dconf color-scheme` (comprobado A/B con la misma instancia:
    # prefer-light => LIGHT, prefer-dark => DARK). El modo oscuro por defecto
    # lo fija modules/system/theme.nix.
    # NOTA: al ser sessionVariables solo surten efecto en el PRÓXIMO login.
  };
}
