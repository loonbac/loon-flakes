# Módulo "system/plymouth": Splash de arranque gráfico (estilo macOS)
# y configuración de arranque silencioso libre de parpadeos (Flicker-Free Boot).
{ config, lib, pkgs, ... }:

let
  mac-plymouth = pkgs.callPackage ../../pkgs/mac-plymouth { };
in
{
  # ---- Plymouth (Splash gráfico estilo macOS) ----
  boot.plymouth = {
    enable = true;
    theme = "mac";
    themePackages = [ mac-plymouth ];
  };

  # ---- Early KMS (Kernel Mode Setting temprano) ----
  # Carga el driver de Intel en el initrd para fijar la resolución nativa
  # antes de que Plymouth dibuje, eliminando el parpadeo de cambio de modo.
  boot.initrd.kernelModules = [ "i915" ];

  # ---- Silent Boot (Arranque 100% limpio sin texto en pantalla) ----
  # Desactiva mensajes de verbose de NixOS stage 1 y del kernel
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;

  boot.kernelParams = [
    "quiet"
    "splash"
    "boot.shell_on_fail"
    "loglevel=3"
    "rd.systemd.show_status=false"
    "rd.udev.log_level=3"
    "udev.log_priority=3"
    # Oculta el cursor parpadeante de la consola en la esquina superior izquierda
    "vt.global_cursor_default=0"
  ];

  # Tiempo de espera del bootloader (0 = arranque directo y fluido;
  # presionar o mantener Espacio durante el encendido abre el menú si se requiere).
  boot.loader.timeout = lib.mkDefault 0;
}
