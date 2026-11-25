# Host de escritorio ASRock B550 Pro4 (Ryzen 7 5700X + NVIDIA).
{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./platform.nix
    ./audio.nix
    ./games-disk.nix
    ./projects-disk.nix
    ./gaming.nix
    ./streaming.nix
    ./sunshine.nix
    ./cross-toolchain.nix
    ./kalamar-toolchain.nix
    ./cloudflared.nix
    ./creator.nix
    ./mdm-respaldo.nix
  ];

  networking.hostName = "nixos-pc";

  # La barra solo se muestra en el monitor principal horizontal; el vertical
  # secundario (HDMI-A-2) queda libre.
  loon.quickshell.screen = "DP-2";

  # Este equipo usa un teclado físico ANSI estadounidense.
  services.xserver.xkb.layout = "us";
  console.keyMap = "us";

  # Servidores de desarrollo expuestos: 5173 = Vite (tele-owo), 8080 = API axum.
  loon.devPorts = [ 5173 8080 ];

  # Gentle Shell desde fuente: compila Shell (pnpm) + Gentle AI (Go) con los
  # últimos commits de main en cada activación que cambie la declaración.
  programs.gentle-ai.gentleShell.channel = "main";

  # Minecraft: el mundo abierto al LAN desde PrismLauncher escucha en *:25565.
  # Se abre solo a la tailnet, no a la LAN ni a internet: la regla se limita a
  # la interfaz tailscale0 en vez de sumar el puerto a allowedTCPPorts, que lo
  # expondría a cualquier equipo de la red local.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 25565 ];

  system.stateVersion = "26.05";
}
