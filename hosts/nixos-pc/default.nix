# Host de escritorio ASRock B550 Pro4 (Ryzen 7 5700X + NVIDIA).
{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./platform.nix
    ./games-disk.nix
    ./projects-disk.nix
    ./gaming.nix
    ./streaming.nix
    ./sunshine.nix
    ./cross-toolchain.nix
    ./cloudflared.nix
    ./creator.nix
  ];

  networking.hostName = "nixos-pc";

  # Only this host's Pi holds these two Antigravity logins. Both catalogues carry
  # Claude 5.5 and Gemini 4 Argon today, so no account is named here: pi-antigravity
  # fails over on a quota wall without checking whether the target account can serve
  # the model in use, which is how a session ended up on a catalogue without 5.5 and
  # the native review could not resolve its reviewer. This unit keeps the active
  # account on one that has the models, and moves only when the current one cannot
  # serve them.
  services.antigravity-keeper = {
    requiredModels = [
      "claude-opus-5-5"
      "claude-sonnet-5-5"
    ];
  };

  # Este equipo usa un teclado físico ANSI estadounidense.
  services.xserver.xkb.layout = "us";
  console.keyMap = "us";

  # Servidores de desarrollo expuestos: 5173 = Vite (tele-owo), 8080 = API axum.
  loon.devPorts = [ 5173 8080 ];

  # Minecraft: el mundo abierto al LAN desde PrismLauncher escucha en *:25565.
  # Se abre solo a la tailnet, no a la LAN ni a internet: la regla se limita a
  # la interfaz tailscale0 en vez de sumar el puerto a allowedTCPPorts, que lo
  # expondría a cualquier equipo de la red local.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 25565 ];

  system.stateVersion = "26.05";
}
