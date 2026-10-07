# Módulo "networking": todo lo relacionado con red.
# La capa de conexión con el mundo.
{ config, lib, pkgs, ... }:

{
  # ---- Puertos de desarrollo ----
  # Cada host declara aquí los puertos TCP de sus servidores de desarrollo
  # (p. ej. un frontend Vite y una API axum). El módulo compartido no fija
  # proyectos concretos: solo suma lo que el host decida exponer.
  options.loon.devPorts = lib.mkOption {
    type = lib.types.listOf lib.types.port;
    default = [ ];
    example = [ 5173 8080 ];
    description = ''
      Puertos TCP de servidores de desarrollo que este host abre en el
      firewall. Ponlos aquí en lugar de fijarlos en el módulo compartido.
    '';
  };

  # Al declarar `options`, la configuración debe ir dentro de `config`.
  config = {
    # Gestor de red (WiFi, ethernet, VPNs por GUI).
    networking.networkmanager.enable = true;

    # Tethering USB con iPhone: ipheth expone el hotspot como una interfaz
    # Ethernet y usbmuxd prepara los permisos y la comunicación con iOS.
    # NetworkManager la detecta y configura automáticamente al activar
    # "Permitir a otros conectarse" en el iPhone.
    boot.kernelModules = [ "ipheth" ];
    services.usbmuxd.enable = true;

    # ---- Firewall ----
    # Por defecto NixOS activa el firewall. Para abrir puertos:
    #   networking.firewall.allowedTCPPorts = [ 80 443 ];
    #   networking.firewall.allowedUDPPorts = [ 53 ];
    # Para desactivarlo del todo (NO recomendado):
    #   networking.firewall.enable = false;
    # Los puertos de desarrollo (5173 = Vite del frontend tele-owo, 8080 = API
    # axum) los declara cada host con `loon.devPorts`.
    networking.firewall.allowedTCPPorts = config.loon.devPorts;
  };
}
