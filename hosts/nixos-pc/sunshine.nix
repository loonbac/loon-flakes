# Streaming de la pantalla actual de nixos-pc para clientes Moonlight.
{ pkgs, ... }:

{
  # Sink exclusivo para Dolphin. module-remap-sink reproduce en el sumidero
  # físico predeterminado sin mezclar el resto del audio de la sesión.
  services.pipewire.extraConfig.pipewire-pulse."45-dolphin-stream" = {
    "pulse.cmd" = [
      {
        cmd = "load-module";
        args = "module-remap-sink sink_name=dolphin_stream sink_properties=device.description=Dolphin-Stream remix=no";
        flags = [ ];
      }
    ];
  };

  services.sunshine = {
    enable = true;
    autoStart = true;
    openFirewall = true;

    # Niri requiere captura DRM/KMS; esta capacidad permite acceder al monitor
    # sin ejecutar todo Sunshine como root.
    capSysAdmin = true;
    settings = {
      sunshine_name = "nixos-pc";
      address_family = "both";
      csrf_allowed_origins = "https://192.168.0.10:47990";
      capture = "kms";
      # Sunshine 2026.516 interpreta incorrectamente el nombre estable DP-2
      # con KMS; su listado de arranque asigna el monitor principal al ID 1.
      output_name = "1";
      # En este paquete de NixOS CUDA/NVENC no resuelve libcuda.so, mientras
      # que el backend Vulkan sí codifica H.264/HEVC en la RTX 3060.
      encoder = "vulkan";
      # Captura solo el audio enviado por el wrapper de Dolphin.
      audio_sink = "dolphin_stream.monitor";
    };

    # Esta entrada no lanza Dolphin: transmite el monitor que ya está activo.
    # El emulador se inicia manualmente antes de que el invitado abra el stream.
    applications.apps = [
      {
        name = "Dolphin";
        image = "desktop.png";
        # No lanza el emulador: si Dolphin no está abierto, rechaza el stream
        # para evitar mostrar accidentalmente el resto del escritorio.
        "prep-cmd" = [
          {
            "do" = "${pkgs.procps}/bin/pgrep -f '[d]olphin-emu' >/dev/null";
            "undo" = "";
          }
        ];
      }
    ];
  };

  # El servicio de usuario se instala globalmente; esta condición evita que el
  # greeter u otra cuenta intente ocupar los mismos puertos.
  systemd.user.services.sunshine.unitConfig.ConditionUser = "loonbac";

  users.users.loonbac.extraGroups = [ "input" ];
}
