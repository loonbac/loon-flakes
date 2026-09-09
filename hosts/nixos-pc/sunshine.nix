# Streaming de la pantalla actual de nixos-pc para clientes Moonlight.
{ ... }:

{
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
    };

    # Una aplicación sin comando transmite el escritorio que ya está activo.
    applications.apps = [
      {
        name = "Desktop";
        image = "desktop.png";
      }
    ];
  };

  # El servicio de usuario se instala globalmente; esta condición evita que el
  # greeter u otra cuenta intente ocupar los mismos puertos.
  systemd.user.services.sunshine.unitConfig.ConditionUser = "loonbac";

  users.users.loonbac.extraGroups = [ "input" ];
}
