# Módulo "programs/swaync": daemon de notificaciones SwayNC con config gestionada por NixOS.
#
# - La config (config.json + style.css) se instala en /etc/swaync (fuente de
#   verdad, versionada) y un tmpfiles rule crea ~/.config/swaync/* como symlinks.
# - SwayNC da prioridad a ~/.config/swaync, por eso los symlinks.
# - accent.css NO es symlink: es un archivo real del usuario que
#   accent-wallpaper sobreescribe con el color del wallpaper (mismo patrón que
#   gtk.css / niri accent.kdl). El rule `f` crea el default si no existe.
# - Recarga en vivo tras un cambio de acento: `swaync-client -R`.
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    swaynotificationcenter
  ];

  # Config gestionada por NixOS: swaync la lee desde el home (symlinks).
  environment.etc."swaync/config.json".source = ./config.json;
  environment.etc."swaync/style.css".source = ./style.css;

  # Default del generado: accent-wallpaper sobreescribe el archivo del usuario
  # con la paleta real del wallpaper, pero hace falta un fallback mientras no
  # haya corrido (home nuevo / primer arranque). Va con `C` y no con `f`: el
  # contenido son varias líneas, `f` solo admite una y la aserción de
  # modules/default.nix rechaza reglas tmpfiles multilínea. `C` copia solo si
  # no existe, así que nunca pisa lo que escriba accent-wallpaper.
  environment.etc."swaync/accent.css".source = ./accent.css;

  # Ruta absoluta: systemd no expande "~" en tmpfiles.
  systemd.tmpfiles.rules = [
    "d /home/saito/.config/swaync 0755 saito users -"
    "L+ /home/saito/.config/swaync/config.json - - - - /etc/swaync/config.json"
    "L+ /home/saito/.config/swaync/style.css - - - - /etc/swaync/style.css"
    # Acento dinámico: lo escribe accent-wallpaper. La regla C copia el
    # default de /etc solo si el archivo no existe, así que nunca pisa la
    # paleta del wallpaper; y a diferencia de `f` admite contenido multilínea
    # (necesario: accent.css define 7 colores, `f` solo admite una línea).
    "C /home/saito/.config/swaync/accent.css 0644 saito users - /etc/swaync/accent.css"
  ];
}
